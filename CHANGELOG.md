# Changelog

As notas completas de cada versão ficam em [`docs/releases/`](docs/releases/) e nas
[releases do GitHub](https://github.com/raphaeltorquat0/Quietbar/releases). As decisões estão em [`DECISIONS.md`](DECISIONS.md).

## 1.4.0 (não publicada)

### Adicionado

- **Automação em chamadas:** aplica o modo escolhido quando um app usa o microfone e restaura o anterior no fim, em qualquer app. Com lista de apps ignorados e espera ajustável. Vem desligada.
- **Filtros de Foco:** um perfil do Quietbar para cada Foco, escolhido nos Ajustes do Sistema.
- **App Intents:** definir modo de ruído, definir nível do ambiente, aplicar perfil, aplicar preset de EQ e consultar bateria, com frases em português e inglês.
- **Motor de prioridade:** ajuste manual › chamada › Foco › perfil por app › perfil por Wi-Fi › padrão, por ajuste.
- Aba **Automação** nas Configurações e indicador da regra ativa no painel e no menu curto.
- Perfis sem gatilho, para Foco e Atalhos.
- **Som no Mac:** EQ paramétrico só para o áudio do Mac, detalhado em [`docs/releases/1.4.0.md`](docs/releases/1.4.0.md).

### Alterado

- Perfis por app e por Wi-Fi agora **voltam atrás** quando deixam de valer. Antes, o último ajuste ficava.
- Abrir as Configurações do Quietbar não conta mais como sair do app em primeiro plano.
- Toda ação no fone passa por uma fila única, sem escritas concorrentes.

### Corrigido

- Quedas do app quando um dispositivo Bluetooth conecta e ao abrir com o fone já conectado.

## Versões anteriores

- [1.3.1](docs/releases/1.3.1.md)
- [1.3.0 e anteriores](https://github.com/raphaeltorquat0/Quietbar/releases)
