# spectre-apple

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | **Español**

Cliente nativo de Apple para el escritorio remoto [ghost](https://github.com/jsaiko/ghost), para macOS, iPadOS e iOS (solo Apple silicon / arm64). La app se llama **Spectre** y su bundle ID es `org.ghost.spectre.apple`.

> **Agradecimientos**: este proyecto está inspirado en [ghost](https://github.com/jsaiko/ghost), de [Joseph Saiko](https://saiko.dev), un sistema completo de escritorio remoto formado por el protocolo GDP, el host wraith y el cliente spectre para Linux. spectre-apple lleva ghost a los dispositivos de Apple: usa la biblioteca de protocolo de ghost, libgdp, está escrito a partir de la especificación del protocolo y los documentos de diseño publicados por ghost, y toma el nombre Spectre del cliente original. Muchas gracias al autor por publicar ghost como código abierto y por liberar libgdp y la especificación del protocolo bajo la licencia MIT; sin ello este proyecto no existiría. spectre-apple es un cliente independiente, de terceros, y no forma parte del proyecto ghost.

![Una sesión en iPad en modo trackpad, con el cursor remoto dibujado por Metal](docs/images/ipad-trackpad-mode.jpg)

- **Protocolo**: libgdp, la biblioteca en C++ del proyecto original (QUIC con ngtcp2 y OpenSSL, protobuf, zstd), compilada como bibliotecas estáticas en un xcframework y expuesta a Swift mediante una fina capa de C ABI.
- **Plataforma**: Swift 6, SwiftUI, Metal y VideoToolbox. La parte cliente de las sesiones, el inicio de sesión y la entrada está escrita a partir de la especificación de GDP (`third_party/ghost/docs/spec/gdp-spec.md`).

Las notas de diseño y las mediciones de [`docs/`](docs/) están escritas en chino simplificado.

## Estado

Funciona:

- **Inicio de sesión**: inicio de sesión en el lobby (§4, §5); el certificado del servidor se confirma en la primera conexión y se recuerda (confianza en el primer uso); autenticación interactiva según las indicaciones del servidor; elección de dispositivo y de sesión de escritorio; toma de control de una sesión en curso. Véase [docs/login.md](docs/login.md).
- **Vídeo**: H.264 y HEVC, decodificados por hardware con VideoToolbox y entregados a Metal sin copias; estadísticas de pérdida de fotogramas y de latencia enviadas al host (StatsReport). Véanse [docs/session-client.md](docs/session-client.md) y [docs/prototype-findings.md](docs/prototype-findings.md).
- **Entrada**: teclas enviadas por posición física; ratón con posiciones absolutas, todos los botones y desplazamiento suave, más un modo capturado que envía movimiento relativo; el cursor remoto se dibuja localmente; en iPad, teclados físicos, trackpads y ratones, y los dedos en modo «toque directo» o «trackpad». Véase [docs/input.md](docs/input.md).
- **Control de sesión**: desconectar (la sesión remota sigue abierta) y cerrar sesión (termina la sesión remota).

Pendiente: audio y micrófono, portapapeles, mandos, la capa de refinamiento sin pérdidas (refine), teclado en pantalla, AV1 y PyroWave.

## Compilación

### Requisitos

- Xcode 27 (con el runtime del simulador de iOS 27)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `cmake` (3.25 o posterior) y `ninja`: `brew install cmake ninja`
- [vcpkg](https://github.com/microsoft/vcpkg), preferiblemente fijado en el commit que usa la CI del proyecto original:

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

Si vcpkg no está en `~/src/vcpkg`, define `VCPKG_ROOT` para los comandos siguientes.

### Pasos

1. Obtén el código, incluido el submódulo de ghost:

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

   En un clon existente, descarga el submódulo con `git submodule update --init`.

2. Compila `GDPCore.xcframework`: libgdp y sus dependencias (bibliotecas estáticas de vcpkg) más el puente en C, unidos en `Packages/GDPKit/Artifacts/GDPCore.xcframework` (no se incluye en git). La primera compilación de las dependencias tarda unos minutos; las siguientes usan la caché binaria de vcpkg. Los registros quedan en `build/logs/`.

   ```bash
   scripts/build-gdpcore.sh
   ```

   Por defecto compila `macos`, `ios` e `ios-simulator`; indica solo algunas para compilar únicamente esas, por ejemplo `scripts/build-gdpcore.sh macos`.

3. Genera el proyecto de Xcode, abre `Spectre.xcodeproj` y ejecuta el esquema `Spectre`:

   ```bash
   xcodegen generate
   ```

   O compila la app de macOS desde la línea de comandos:

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

Para ejecutarla en un dispositivo, elige un equipo de desarrollo para el target en Xcode.

## Uso

La app se abre en la pantalla de inicio de sesión: introduce el servidor (`host[:port]`, puerto 4442 por defecto) y tu nombre de usuario, responde a las indicaciones del servidor y elige un escritorio para iniciar la sesión. En la primera conexión se te pide que confirmes la huella del certificado del servidor.

**¿No tienes servidor?** Pulsa **Try the demo host** (usuario demo, contraseña demo): la app inicia dentro de sí misma un lobby y un host de prueba y recorre todo el flujo de inicio de sesión y de sesión, mostrando un flujo de prueba; la capa de estadísticas lista la entrada que recibió el host.

**Teclado y ratón**: las teclas se envían por posición física y la distribución de teclado remota decide qué caracteres escriben. Cmd se envía como Super (la tecla Windows), así que copiar y pegar en el escritorio remoto siguen siendo Ctrl+C y Ctrl+V. Solo estos tres atajos se quedan en local:

| Atajo | Acción |
|---|---|
| Ctrl+Cmd+G | Capturar o liberar el ratón (movimiento relativo para juegos y vistas 3D); también el botón Capture Mouse de la barra de herramientas |
| Ctrl+Cmd+F | Pantalla completa |
| Cmd+Q | Salir |

**Dedos en iPad y iPhone**: cambia entre dos modos con el botón de la barra de herramientas.

- **Touch**: el puntero va donde tocas. Toca para hacer clic izquierdo, mantén pulsado para el clic derecho, arrastra con un dedo para arrastrar con el botón izquierdo, arrastra con dos dedos para desplazarte y toca con dos o tres dedos para el clic derecho o central.
- **Trackpad**: la pantalla funciona como un trackpad. Mueve el cursor con un dedo y toca para hacer clic.

## Desarrollo

### Pruebas

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

Ambos paquetes incluyen un host de prueba (y un lobby de prueba) dentro del proceso para pruebas de extremo a extremo sobre una conexión QUIC real de loopback. Las pruebas de SpectreKit además comprueban los colores de barras de color H.264 y HEVC y renderizan con Metal. Para ejecutarlas en el simulador de iPad:

```bash
(cd Packages/GDPKit && xcodebuild test -scheme GDPKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-GDPKit)
```

```bash
(cd Packages/SpectreKit && xcodebuild test -scheme SpectreKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-SpectreKit)
```

### Saltarse el inicio de sesión

Si se inicia con cualquiera de las opciones siguientes, la app se salta el inicio de sesión y reproduce directamente. Primero codifica con VideoToolbox un flujo de prueba de 10 segundos a 1080p60 (unos 3 segundos) y luego lo repite en bucle; arriba a la izquierda muestra estadísticas de decodificación, presentación y sesión, que se actualizan cada segundo y también se imprimen en stdout. La barra de herramientas cambia la fuente, H.264/HEVC y el ritmo de presentación. Hay tres fuentes:

- **Loopback** (por defecto): un host de prueba dentro de la app envía el flujo de prueba por una sesión GDP real (QUIC en 127.0.0.1).
- **Direct**: el flujo de prueba va directamente al decodificador, sin red.
- **Remote**: un wraith iniciado con un token estático (§6.11):

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --connect HOST:PORT --token TOKEN --fingerprint SHA256
```

Modo de medición: mide durante N segundos tras un calentamiento de 2 segundos, imprime las estadísticas y sale.

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

Otras opciones: `--source loopback|direct`, `--codec h264|h265`, `--mode onArrival|displayLink`, `--in-flight <N, 0 sin límite>`, `--screen <índice de pantalla>`, `--rate <Hz del display link>`, `--min-present-ms <ms>`.

### Simulador de iOS y iPadOS

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

En iOS la app arranca desde un app delegate de UIKit, para que su view controller raíz pueda bloquear el puntero (véase [docs/input.md](docs/input.md)). Si había instalada una versión anterior (con el punto de entrada de SwiftUI), desinstálala una vez (`xcrun simctl uninstall booted org.ghost.spectre.apple`); de lo contrario, el sistema restaura la ventana antigua y se queda en negro.

En el simulador VideoToolbox decodifica por software y no hay `presentedTime`, así que los tiempos medidos allí no se pueden comparar con los de un dispositivo o macOS.

### Estructura

| Ruta | Contenido |
|---|---|
| `project.yml` | Proyecto de XcodeGen (un único target de app multiplataforma macOS + iOS) |
| `App/` | Puntos de entrada de cada plataforma y la interfaz (inicio de sesión, sesión) |
| `Packages/GDPKit/` | El puente en C a libgdp (`Native/`) y su capa en Swift: sesiones, lobby, host de prueba |
| `Packages/SpectreKit/` | Código compartido: sesión, decodificación con VideoToolbox, presentación con Metal, entrada, flujo de inicio de sesión |
| `scripts/` | Scripts que compilan las dependencias y el xcframework |
| `docs/` | Notas de diseño y mediciones (en chino simplificado) |
| `experiments/` | Experimentos puntuales (como una prueba de interoperabilidad Swift/C++), fuera de la compilación de la app |
| `third_party/ghost/` | ghost original (submódulo de git, solo lectura) |

### Documentos

- [docs/prototype-findings.md](docs/prototype-findings.md): los tres riesgos técnicos del prototipo y cómo se resolvió cada uno (llamar a libgdp desde Swift, presentación sin copias, compilación cruzada para iOS)
- [docs/session-client.md](docs/session-client.md): la capa de sesión, contrastada con los §6–§11 de la especificación
- [docs/login.md](docs/login.md): inicio de sesión en el lobby, confianza en certificados, la demo
- [docs/input.md](docs/input.md): teclado, ratón, cursor, toque

## Licencia

[MIT](LICENSE).

- En el proyecto ghost original, `libgdp/` y la especificación del protocolo son MIT, y todo lo demás (incluido su propio cliente spectre) es GPL-3.0-only. Este proyecto solo compila `libgdp/`; su código cliente está escrito a partir de la especificación y de estándares públicos, y no copia ni adapta código de las partes GPL.
- La app enlaza estáticamente ngtcp2, OpenSSL, Protocol Buffers, Abseil y zstd, todas con licencias permisivas (MIT, Apache-2.0, BSD-3-Clause). Una distribución binaria debe incluir sus avisos de licencia: véase [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
