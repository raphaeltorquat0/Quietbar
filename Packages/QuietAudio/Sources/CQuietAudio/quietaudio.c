#include "quietaudio.h"
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK 1024
#define COEFF_RAMP_SECONDS 0.03
#define MIX_RAMP_SECONDS 0.01
#define FADE_RAMP_SECONDS 0.03
#define LIMITER_HOLD_SECONDS 0.03 // cobre meio período de 20 Hz: o ganho não respira entre dois picos
#define LIMITER_RELEASE_SECONDS 0.1
#define LIMITER_CEILING 0.891 // -1 dBFS
#define TONE_HZ 1000.0
#define TONE_LEVEL 0.1 // -20 dBFS
#define SIGNAL_FLOOR 1e-6f // -120 dBFS: abaixo disso é silêncio digital

static const qa_coeffs identity = {1, 0, 0, 0, 0};

struct qa_chain {
    // Triple buffer: o escritor nunca espera o render e o render nunca vê uma escrita pela metade.
    qa_params slots[3];
    atomic_int mailbox; // índice do slot | DIRTY
    int write_slot, read_slot;

    atomic_bool bypass, fade_open, tone;
    _Atomic uint64_t frames, last_signal_frame;
    _Atomic uint32_t output_peak, load, latency; // bits de float

    double sample_rate;
    int input_offset;
    double ticks_per_second;

    qa_coeffs current[QA_MAX_FILTERS], target[QA_MAX_FILTERS], step[QA_MAX_FILTERS];
    double state[2][QA_MAX_FILTERS][2];
    int active;
    int ramp_left, ramp_len;
    double preamp, preamp_target, preamp_step;

    double limiter_gain, limiter_release;
    int limiter_hold, limiter_hold_left;
    double mix, mix_step, fade, fade_step;
    double tone_phase, tone_step;

    double wet[2][BLOCK];
    float scratch[2][BLOCK];
};

#define DIRTY 4

static uint32_t float_bits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float bits_float(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

qa_chain *qa_chain_create(void) {
    qa_chain *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    c->ticks_per_second = 1e9 * (double)tb.denom / (double)tb.numer;
    c->write_slot = 0;
    c->read_slot = 1;
    atomic_init(&c->mailbox, 2);
    for (int s = 0; s < 3; s++) c->slots[s].preamp = 1;
    qa_chain_reset(c, 48000, 0);
    return c;
}

void qa_chain_destroy(qa_chain *c) { free(c); }

static bool take_params(qa_chain *c) {
    if (!(atomic_load_explicit(&c->mailbox, memory_order_acquire) & DIRTY)) return false;
    c->read_slot = atomic_exchange_explicit(&c->mailbox, c->read_slot, memory_order_acq_rel) & 3;
    return true;
}

/// Só roda até o último filtro que não é neutro.
static void trim_active(qa_chain *c) {
    c->active = 0;
    for (int f = 0; f < QA_MAX_FILTERS; f++)
        if (memcmp(&c->target[f], &identity, sizeof identity) != 0) c->active = f + 1;
}

static void load_targets(qa_chain *c) {
    const qa_params *p = &c->slots[c->read_slot];
    for (int i = 0; i < QA_MAX_FILTERS; i++) c->target[i] = i < p->count ? p->filters[i] : identity;
    c->preamp_target = p->preamp;
}

void qa_chain_reset(qa_chain *c, double sample_rate, int input_channel_offset) {
    c->sample_rate = sample_rate;
    c->input_offset = input_channel_offset;
    take_params(c);
    load_targets(c);
    memcpy(c->current, c->target, sizeof c->current);
    memset(c->state, 0, sizeof c->state);
    trim_active(c);
    c->ramp_left = 0;
    c->ramp_len = (int)(COEFF_RAMP_SECONDS * sample_rate);
    c->preamp = c->preamp_target;
    c->preamp_step = 0;
    c->limiter_gain = 1;
    c->limiter_hold = (int)(LIMITER_HOLD_SECONDS * sample_rate);
    c->limiter_hold_left = 0;
    c->limiter_release = 1 - exp(-1 / (LIMITER_RELEASE_SECONDS * sample_rate));
    c->mix = atomic_load(&c->bypass) ? 0 : 1;
    c->mix_step = 1 / (MIX_RAMP_SECONDS * sample_rate);
    c->fade = 0;
    c->fade_step = 1 / (FADE_RAMP_SECONDS * sample_rate);
    c->tone_phase = 0;
    c->tone_step = 2 * M_PI * TONE_HZ / sample_rate;
    atomic_store(&c->fade_open, false);
    atomic_store(&c->frames, 0);
    atomic_store(&c->last_signal_frame, 0);
    atomic_store(&c->output_peak, 0);
    atomic_store(&c->load, 0);
    atomic_store(&c->latency, 0);
}

void qa_chain_set_params(qa_chain *c, const qa_params *p) {
    c->slots[c->write_slot] = *p;
    c->write_slot = atomic_exchange_explicit(&c->mailbox, c->write_slot | DIRTY, memory_order_acq_rel) & 3;
}

void qa_chain_set_bypass(qa_chain *c, bool bypass) { atomic_store(&c->bypass, bypass); }
void qa_chain_set_fade(qa_chain *c, bool open) { atomic_store(&c->fade_open, open); }
void qa_chain_set_tone(qa_chain *c, bool on) { atomic_store(&c->tone, on); }

qa_stats qa_chain_read_stats(qa_chain *c) {
    return (qa_stats){
        .frames = atomic_load(&c->frames),
        .last_signal_frame = atomic_load(&c->last_signal_frame),
        .output_peak = bits_float(atomic_exchange(&c->output_peak, 0)),
        .load = bits_float(atomic_load(&c->load)),
        .latency = bits_float(atomic_load(&c->latency)),
    };
}

static void start_ramp(qa_chain *c) {
    load_targets(c);
    double n = c->ramp_len;
    for (int i = 0; i < QA_MAX_FILTERS; i++) {
        c->step[i] = (qa_coeffs){(c->target[i].b0 - c->current[i].b0) / n, (c->target[i].b1 - c->current[i].b1) / n,
                                 (c->target[i].b2 - c->current[i].b2) / n, (c->target[i].a1 - c->current[i].a1) / n,
                                 (c->target[i].a2 - c->current[i].a2) / n};
    }
    c->preamp_step = (c->preamp_target - c->preamp) / n;
    c->ramp_left = c->ramp_len;
    c->active = QA_MAX_FILTERS;
}

// Forma direta II transposta. Interpolar os coeficientes é estável: a região de estabilidade
// de (a1, a2) é um triângulo, convexo, e cada passo é uma combinação convexa de dois filtros estáveis.
static void run_filter(qa_coeffs k, const qa_coeffs *ramp, double z[2], double *x, int n) {
    double z1 = z[0], z2 = z[1];
    for (int i = 0; i < n; i++) {
        double in = x[i], y = k.b0 * in + z1;
        z1 = k.b1 * in - k.a1 * y + z2;
        z2 = k.b2 * in - k.a2 * y;
        x[i] = y;
        if (ramp) { k.b0 += ramp->b0; k.b1 += ramp->b1; k.b2 += ramp->b2; k.a1 += ramp->a1; k.a2 += ramp->a2; }
    }
    z[0] = fabs(z1) < 1e-30 ? 0 : z1; // denormais custam caro no x86
    z[1] = fabs(z2) < 1e-30 ? 0 : z2;
}

static void filter_block(qa_chain *c, int n) {
    int done = 0;
    while (done < n) {
        int seg = c->ramp_left > 0 && c->ramp_left < n - done ? c->ramp_left : n - done;
        bool ramping = c->ramp_left > 0;
        for (int ch = 0; ch < 2; ch++) {
            double *x = c->wet[ch] + done;
            double g = c->preamp;
            for (int i = 0; i < seg; i++) { x[i] *= g; if (ramping) g += c->preamp_step; }
            for (int f = 0; f < c->active; f++) run_filter(c->current[f], ramping ? &c->step[f] : NULL, c->state[ch][f], x, seg);
        }
        if (ramping) {
            for (int f = 0; f < QA_MAX_FILTERS; f++) {
                c->current[f].b0 += c->step[f].b0 * seg; c->current[f].b1 += c->step[f].b1 * seg;
                c->current[f].b2 += c->step[f].b2 * seg; c->current[f].a1 += c->step[f].a1 * seg;
                c->current[f].a2 += c->step[f].a2 * seg;
            }
            c->preamp += c->preamp_step * seg;
            c->ramp_left -= seg;
            if (c->ramp_left == 0) { // fecha exato no alvo e deixa de rodar os filtros neutros do fim
                memcpy(c->current, c->target, sizeof c->current);
                c->preamp = c->preamp_target;
                trim_active(c);
            }
        }
        done += seg;
    }
}

static void process_block(qa_chain *c, float *l, float *r, int n) {
    if (take_params(c)) start_ramp(c);

    bool signal = false;
    for (int i = 0; i < n; i++) if (fabsf(l[i]) > SIGNAL_FLOOR || fabsf(r[i]) > SIGNAL_FLOOR) { signal = true; break; }

    if (atomic_load_explicit(&c->tone, memory_order_relaxed)) {
        for (int i = 0; i < n; i++) {
            l[i] = r[i] = (float)(TONE_LEVEL * sin(c->tone_phase));
            c->tone_phase = fmod(c->tone_phase + c->tone_step, 2 * M_PI);
        }
    }
    for (int i = 0; i < n; i++) { c->wet[0][i] = l[i]; c->wet[1][i] = r[i]; }
    filter_block(c, n);

    double mix_target = atomic_load_explicit(&c->bypass, memory_order_relaxed) ? 0 : 1;
    double fade_target = atomic_load_explicit(&c->fade_open, memory_order_relaxed) ? 1 : 0;
    double lg = c->limiter_gain, mix = c->mix, fade = c->fade;
    int hold = c->limiter_hold_left;
    float peak = 0;
    for (int i = 0; i < n; i++) {
        double a = c->wet[0][i], b = c->wet[1][i];
        double level = fmax(fabs(a), fabs(b));
        double want = level > LIMITER_CEILING ? LIMITER_CEILING / level : 1;
        if (want < lg) { lg = want; hold = c->limiter_hold; }
        else if (hold > 0) hold--;
        else lg += (want - lg) * c->limiter_release;

        mix += fmax(-c->mix_step, fmin(c->mix_step, mix_target - mix));
        fade += fmax(-c->fade_step, fmin(c->fade_step, fade_target - fade));

        // O caminho seco não passa pelo limitador: bypass é o sinal original.
        float ol = (float)((l[i] + (a * lg - l[i]) * mix) * fade);
        float or_ = (float)((r[i] + (b * lg - r[i]) * mix) * fade);
        l[i] = ol;
        r[i] = or_;
        peak = fmaxf(peak, fmaxf(fabsf(ol), fabsf(or_)));
    }
    c->limiter_gain = lg;
    c->limiter_hold_left = hold;
    c->mix = mix;
    c->fade = fade;

    uint64_t frames = atomic_load_explicit(&c->frames, memory_order_relaxed) + (uint64_t)n;
    atomic_store_explicit(&c->frames, frames, memory_order_relaxed);
    if (signal) atomic_store_explicit(&c->last_signal_frame, frames, memory_order_relaxed);
    if (peak > bits_float(atomic_load_explicit(&c->output_peak, memory_order_relaxed)))
        atomic_store_explicit(&c->output_peak, float_bits(peak), memory_order_relaxed);
}

void qa_chain_process(qa_chain *c, float *l, float *r, int frames) {
    while (frames > 0) {
        int n = frames < BLOCK ? frames : BLOCK;
        process_block(c, l, r, n);
        l += n; r += n; frames -= n;
    }
}

// MARK: - IOProc

/// Copia `n` quadros do canal `ch` a partir de `offset`. Devolve `false` se a lista não tem o canal.
static bool read_channel(const AudioBufferList *list, int ch, float *dst, int offset, int n) {
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buf = &list->mBuffers[b];
        int channels = (int)buf->mNumberChannels;
        if (ch < channels) {
            int have = (int)(buf->mDataByteSize / sizeof(float)) / channels;
            const float *src = (const float *)buf->mData + ch;
            for (int i = 0; i < n; i++) dst[i] = offset + i < have ? src[(offset + i) * channels] : 0;
            return true;
        }
        ch -= channels;
    }
    return false;
}

static void write_channel(AudioBufferList *list, int ch, const float *src, int offset, int n) {
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        AudioBuffer *buf = &list->mBuffers[b];
        int channels = (int)buf->mNumberChannels;
        if (ch < channels) {
            int have = (int)(buf->mDataByteSize / sizeof(float)) / channels;
            float *dst = (float *)buf->mData + ch;
            for (int i = 0; i < n && offset + i < have; i++) dst[(offset + i) * channels] = src[i];
            return;
        }
        ch -= channels;
    }
}

OSStatus qa_io_proc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                    const AudioTimeStamp *input_time, AudioBufferList *output,
                    const AudioTimeStamp *output_time, void *client) {
    (void)device; (void)now;
    qa_chain *c = client;
    if (!output || output->mNumberBuffers == 0 || output->mBuffers[0].mNumberChannels == 0) return noErr;
    uint64_t start = mach_absolute_time();

    int total = (int)(output->mBuffers[0].mDataByteSize / sizeof(float)) / (int)output->mBuffers[0].mNumberChannels;
    float *l = c->scratch[0], *r = c->scratch[1];
    for (int done = 0; done < total;) {
        int n = total - done < BLOCK ? total - done : BLOCK;
        if (input && read_channel(input, c->input_offset, l, done, n)) {
            if (!read_channel(input, c->input_offset + 1, r, done, n)) memcpy(r, l, (size_t)n * sizeof(float));
        } else {
            memset(l, 0, (size_t)n * sizeof(float));
            memset(r, 0, (size_t)n * sizeof(float));
        }
        process_block(c, l, r, n);
        write_channel(output, 0, l, done, n);
        write_channel(output, 1, r, done, n);
        done += n;
    }

    double seconds = (double)(mach_absolute_time() - start) / c->ticks_per_second;
    float load = (float)(seconds * c->sample_rate / (total > 0 ? total : 1));
    atomic_store_explicit(&c->load, float_bits(load), memory_order_relaxed);
    if (input_time && output_time && (input_time->mFlags & kAudioTimeStampHostTimeValid)
        && (output_time->mFlags & kAudioTimeStampHostTimeValid)) {
        float latency = (float)(((double)output_time->mHostTime - (double)input_time->mHostTime) / c->ticks_per_second);
        atomic_store_explicit(&c->latency, float_bits(latency), memory_order_relaxed);
    }
    return noErr;
}
