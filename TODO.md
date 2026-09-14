# Plataformas adiadas

Atualização de 2026-09-12: por nova solicitação do usuário, Linux e Android foram reativados junto ao Windows. As fontes, scripts e exemplos ativos estão na raiz; [PLATFORMS.md](PLATFORMS.md) documenta builds e testes atuais. iOS, macOS e o workflow multiplataforma continuam adiados. As cópias em `todo/` e a tabela abaixo preservam o estado histórico anterior à retomada; não devem substituir os arquivos ativos.

## Histórico anterior à retomada de Linux/Android

| Plataforma | Evidência obtida nesta sessão | Falta validar |
|---|---|---|
| Android | Seis bibliotecas de arm64-v8a, armeabi-v7a e x86_64 recompiladas com NDK 28.2.13676358 e OpenSSL 3.5.8 estático. Todos os ELF passaram no alinhamento de 16 KB. Símbolos exigidos conferidos; dependências somente libc/libm/libdl. APK release e AAB release compilaram. APK passou no zipalign de 16 KB e todos os ELF extraídos, inclusive Flutter/app, passaram. | Configuração de alinhamento do AAB, instalação/execução em emulador de 16 KB e testes SQL/TLS no Android. Nenhum dispositivo/AVD/imagem estava disponível. |
| iOS | Podspec, preservação de símbolos FFI, registro e scripts de OpenSSL/FreeTDS para dispositivo e simuladores preparados. | Compilação em macOS, linkage e execução. XCFrameworks existentes não foram recompilados nem validados. |
| macOS | Podspec, loader de bundle, scripts com install name @rpath e permissões de rede do exemplo preparados. | Recompilar arm64/x64, assinatura, dependências e execução fora da máquina de build. |
| Linux | CMake de empacotamento, loader absoluto e exportação da inicialização segura em autotools preparados. | Recompilar, conferir ABI/dependências/RPATH/glibc mínima e executar em ambiente limpo. |

## Retomada

1. Restaurar de `todo/` os caminhos da plataforma escolhida e seus scripts. Não executar os scripts arquivados presumindo que os caminhos já foram ajustados.
2. Reintroduzir somente a plataforma em validação no `pubspec.yaml` e regenerar os arquivos Flutter.
3. O workflow em `todo/.github/workflows/freetds-multi.yml` é um rascunho não executado. Revisar antes de reativar.
4. Recompilar os artefatos antigos de iOS/macOS/Linux: o Dart exige as extensões nativas de segurança e rejeita bibliotecas antigas.
5. Usar servidor de testes explicitamente confirmado, CA confiável e hostname válido. Nunca desativar TLS para fazer um teste passar.

Builds locais Android permanecem como saídas ignoradas em `example/build/`; as fontes e os binários distribuíveis foram preservados em `todo/`. APK/AAB gerados são apenas artefatos de teste, assinados com a configuração de debug do exemplo.

## Windows: pendência atual

Atualização: a integração SQL Windows passou usando `trustServerCertificate: true`, opção explícita solicitada posteriormente. A configuração TLS manual de CA/hostname permanece **não testada de ponta a ponta com certificado confiável**. O parágrafo abaixo registra o bloqueio anterior à flag.

Windows x64 compilou em release; 21 testes Dart simulados e 3 testes nativos passaram. A integração SQL parou antes das consultas porque o servidor apresentou certificado autoassinado. É necessário fornecer o PEM confiável e o hostname para validar RPC, datas, valores exatos, bulk e transações de ponta a ponta. Isso impede afirmar que todas as correções já estão validadas com SQL Server. ARM64 não foi validado.
