// Cadeia de DSP em C: tudo que roda na thread de áudio mora aqui, para não haver runtime Swift
// (ARC, metadados, locks internos) no caminho de tempo real. Ver docs/AUDIO.md.
#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#define QA_MAX_FILTERS 10

typedef struct { double b0, b1, b2, a1, a2; } qa_coeffs;

/// `count` filtros em série + ganho linear aplicado antes deles.
typedef struct {
    qa_coeffs filters[QA_MAX_FILTERS];
    int count;
    double preamp;
} qa_params;

typedef struct {
    uint64_t frames;            // quadros processados desde o reset
    uint64_t last_signal_frame; // `frames` do último bloco com sinal de verdade na entrada
    float output_peak;          // pico desde a última leitura
    float load;                 // tempo de render / duração do bloco
    float latency;              // segundos entre a entrada e a saída do último ciclo
} qa_stats;

typedef struct qa_chain qa_chain;

qa_chain *qa_chain_create(void);
void qa_chain_destroy(qa_chain *c);

// Fora da thread de áudio, com o IOProc parado.
void qa_chain_reset(qa_chain *c, double sample_rate, int input_channel_offset);

// Um escritor por vez (o app chama só da main thread); nunca bloqueia o render.
void qa_chain_set_params(qa_chain *c, const qa_params *p);
void qa_chain_set_bypass(qa_chain *c, bool bypass);
void qa_chain_set_fade(qa_chain *c, bool open);
void qa_chain_set_tone(qa_chain *c, bool on);
qa_stats qa_chain_read_stats(qa_chain *c);

// Thread de áudio (ou render offline). `l` e `r` são processados no lugar.
void qa_chain_process(qa_chain *c, float *l, float *r, int frames);

OSStatus qa_io_proc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
                    const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull input_time,
                    AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull output_time, void *_Nullable client);
