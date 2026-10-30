# LinkedIn

Publiquei o Quietbar, um app de código aberto para controlar fones Sony pela barra de menus do macOS, sem o app do celular.

[Uma ou duas frases sobre por que você fez o projeto.]

A parte que mais me ensinou foi conversar direto com o fone. O app abre um canal RFCOMM pelo IOBluetooth e fala o protocolo MDR v2: frames com escape, checksum, número de sequência e ACK. Um actor em Swift é o único dono do canal e envia um comando por vez. A interface só muda quando o fone confirma o novo estado, e os testes rodam contra tráfego real gravado.

Separei a camada do protocolo em um pacote Swift, o MDRKit, para quem quiser construir outra coisa em cima dele. O modelo 3D do fone no popup de conexão é todo gerado em código, sem arquivos de malha.

O projeto ainda é cedo. Testei em um WH-1000XM5, os outros modelos com o mesmo protocolo são experimentais, e o XM4 e o XM3 estão no roadmap. O app ainda não é notarizado.

É gratuito, licença MIT, sem conta e sem acesso à rede. Não tem afiliação com a Sony.

Quem tiver outro fone Sony e quiser testar ajuda muito: https://github.com/raphaeltorquat0/Quietbar

#Swift #macOS #OpenSource #Bluetooth
