<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="El icono de Spectre">

# spectre-apple

**Spectre**, un cliente nativo del escritorio remoto [ghost](https://github.com/jsaiko/ghost) para Mac, iPad e iPhone

[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iPadOS%20%7C%20iOS%2027-lightgrey)](#requisitos)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | **Español**

</div>

![Spectre en el Mac, conectado a un escritorio GNOME en un host Ubuntu](docs/images/macos-session.webp)

ghost es un sistema de escritorio remoto de código abierto: un host (wraith) transmite un escritorio Linux mediante el protocolo GDP, y un cliente lo muestra y devuelve la entrada. spectre-apple lleva ese cliente a los dispositivos de Apple como una app nativa, escrita en Swift con SwiftUI, Metal y VideoToolbox, sobre la propia biblioteca de protocolo de ghost, libgdp.

spectre-apple es un cliente independiente, de terceros, inspirado en ghost; no forma parte del proyecto ghost. Consulta los [agradecimientos](#agradecimientos).

## Funciones

**Inicio de sesión**

- Inicia sesión en un servidor ghost con tu nombre de usuario y contraseña; las demás preguntas, como un código de un solo uso, se hacen por turno. Después eliges un dispositivo y una sesión de escritorio, o tomas el control de una que ya está en marcha.
- Confianza en el primer uso: en la primera conexión confirmas la huella del certificado del servidor, y se recuerda. **Servidores de confianza…**, en la pantalla de inicio de sesión, muestra las huellas recordadas y te permite olvidarlas.
- Marca **Recordar** para guardar un inicio de sesión en el llavero, solo en este dispositivo; después, un inicio de sesión reciente se conecta con un toque.
- Una conexión perdida (al cambiar de Wi-Fi, al dormirse el Mac o al suspender iOS la app) se vuelve a conectar sola.

**Imagen y sonido**

- H.264 y HEVC, decodificados por hardware con VideoToolbox y mostrados con Metal sin copiar fotogramas; las pérdidas de fotogramas y la latencia se comunican al host.
- El escritorio remoto se ajusta al tamaño de la ventana, o de la pantalla en iPad y iPhone. **Resolución** en la barra de herramientas lo desactiva o pide la resolución Retina completa.
- El sonido del escritorio remoto, con un búfer de fluctuación que disimula los paquetes perdidos, y un botón para silenciarlo.
- Tu micrófono, enviado al escritorio remoto mientras lo tengas activado.

**Entrada**

- Las teclas se envían por su posición física, así que la distribución de teclado remota decide qué escriben.
- Ratón con todos los botones y desplazamiento suave, y un modo capturado con movimiento relativo para juegos y vistas 3D. El cursor remoto se dibuja localmente.
- En iPad: teclados, trackpads y ratones físicos, y los dedos en modo de toque directo o de trackpad.
- En iPhone y iPad: el teclado en pantalla escribe en el escritorio remoto, con la barra de teclas encima.

**En iPad y iPhone**

- El escritorio remoto ocupa toda la pantalla. Los controles flotan encima en Liquid Glass y se recogen en dos botones redondos en las esquinas inferiores: a la izquierda, la barra de la sesión (Más, pegar en el host, el teclado); a la derecha, una barra de teclas con flechas, Esc, Ctrl+C, Tab, Retroceso e Intro, Ctrl, Alt, Super y Mayús que quedan pulsadas hasta la siguiente tecla, y las combinaciones que iPadOS se reserva, como Super+Tab.
- Un panel de texto: escribe con los métodos de entrada del iPad, el dictado o pegando, y envíalo todo de una vez al cursor del host, mediante su portapapeles y Ctrl+Mayús+V (o Ctrl+V, o tecleado).
- Pellizca para ampliar la imagen, o **Llenar la pantalla**; ampliada, la imagen sigue al puntero cerca de los bordes.
- Avisos de región: enmarca una parte del escritorio remoto, como la salida de un terminal, y Spectre te avisa cuando deja de cambiar (terminó una compilación) o empieza a cambiar, con un banner, o una notificación si su ventana no es la activa.
- Una pantalla de inicio con tus hosts y la última imagen de cada uno, y un menú **Sesión** en la barra de menús del iPad, sin atajos que quiten teclas al escritorio remoto.

**Compartir**

- Portapapeles de texto en ambos sentidos, desactivado hasta que lo actives.
- Hasta cuatro mandos, reenviados como mandos estándar.

**Y además**

- Desconectar (la sesión remota sigue en marcha) o cerrar sesión (la termina).
- La interfaz está en inglés, chino simplificado, chino tradicional, japonés y español, según el idioma del sistema.

### Hoja de ruta

Pendiente:

- La capa de refinamiento sin pérdidas (refine) y los códecs AV1 y PyroWave
- Cancelación de eco para el micrófono
- Comprobar en iOS los certificados emitidos por una autoridad de certificación (por ahora se confía en ellos en el primer uso, como en cualquier otro)

## Capturas de pantalla

| Inicio de sesión en el Mac | iPad en modo trackpad |
|---|---|
| ![La pantalla de inicio de sesión en el Mac](docs/images/macos-login.webp) | ![Una sesión en iPad en modo trackpad, con el cursor remoto dibujado por Metal](docs/images/ipad-trackpad-mode.jpg) |

## Requisitos

- Un Mac con Apple silicon y macOS 27, o un iPhone o iPad con iOS o iPadOS 27 (solo arm64)
- Un host ghost al que conectarte (ghostd y wraith); consulta el proyecto [ghost](https://github.com/jsaiko/ghost) para montar uno

## Primeros pasos

La app para Mac está en [GitHub Releases](https://github.com/pokoblin/spectre-apple/releases/latest): descarga el `.dmg`, ábrelo y arrastra Spectre a Aplicaciones. Está firmada con un Developer ID y notarizada por Apple.

Para iPhone y iPad, o para trabajar en Spectre, compílalo desde el código fuente como se explica a continuación.

### Herramientas

- Xcode 27, con el entorno de ejecución del simulador de iOS 27
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `cmake` (3.25 o posterior) y `ninja`: `brew install cmake ninja`
- [vcpkg](https://github.com/microsoft/vcpkg), a ser posible fijado en el commit que usa la CI del proyecto original:

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

Si tienes vcpkg en otro sitio que no sea `~/src/vcpkg`, define `VCPKG_ROOT`.

### Compilación

1. Clona el repositorio junto con el submódulo de ghost (en un clon existente, ejecuta `git submodule update --init`):

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

2. Compila `GDPCore.xcframework`, que reúne libgdp, sus dependencias y un pequeño puente en C. Se genera en `Packages/GDPKit/Artifacts/` y no se incluye en el repositorio. La primera compilación tarda unos minutos; las siguientes reutilizan la caché binaria de vcpkg. Los registros van a `build/logs/`.

   ```bash
   scripts/build-gdpcore.sh
   ```

   Compila los slices `macos`, `ios` e `ios-simulator`; indica algunos de ellos para compilar solo esos, por ejemplo `scripts/build-gdpcore.sh macos`.

3. Genera el proyecto de Xcode, abre `Spectre.xcodeproj` y ejecuta el esquema `Spectre`:

   ```bash
   xcodegen generate
   ```

   O compila la app para Mac desde la línea de comandos:

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

4. Para quedarte con la app para Mac, cópiala a Aplicaciones:

   ```bash
   ditto build/DerivedData/Build/Products/Release/Spectre.app /Applications/Spectre.app
   ```

Para ejecutar Spectre en un iPhone o iPad, elige tu equipo de desarrollo para el target en Xcode.

## Uso

Spectre se abre en la pantalla de inicio de sesión. Escribe el servidor (`host` o `host:port`; el puerto por omisión es 4442), tu nombre de usuario y contraseña, y elige un escritorio. En la primera conexión se te pide que confirmes la huella del certificado del servidor. Si el servidor pide algo más, como un código de un solo uso, se pregunta aparte; deja la contraseña vacía para responder así a todas las preguntas.

### Teclado y ratón

Cmd se envía como Super (la tecla Windows), así que copiar y pegar en el escritorio remoto siguen siendo Ctrl+C y Ctrl+V. Solo estos atajos se quedan en tu Mac:

| Atajo | Acción |
|---|---|
| Ctrl+Cmd+G | Capturar o liberar el ratón (también con el botón Capturar ratón de la barra de herramientas) |
| Ctrl+Cmd+F | Pantalla completa |
| Cmd+Q | Salir |

### Toques en iPad y iPhone

La barra de herramientas cambia entre dos modos:

- **Táctil**: el puntero va donde tocas. Toca para hacer clic, mantén pulsado para el clic derecho, arrastra con un dedo para arrastrar, arrastra con dos dedos para desplazarte y toca con dos o tres dedos para el clic derecho o central.
- **Trackpad** (predeterminado): la pantalla funciona como un trackpad. Mueve el cursor con un dedo y toca para hacer clic.

### Sonido y micrófono

El sonido del escritorio remoto se reproduce cuando el host lo envía (wraith lo hace cuando puede capturar el audio de la sesión). **Silenciar**, en la barra de herramientas, lo silencia solo en este dispositivo, y el ajuste se recuerda.

**Micrófono**, en la barra de herramientas, envía tu micrófono al escritorio remoto, donde pasa a ser el dispositivo de grabación por omisión de la sesión. Empieza desactivado en cada sesión, y la primera vez el sistema pide permiso. Todavía no hay cancelación de eco, así que usa auriculares, o el escritorio remoto oirá su propio sonido.

## Desarrollo

### Pruebas

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

Los dos paquetes incluyen un host y un lobby de prueba dentro del proceso, así que las pruebas de extremo a extremo usan una conexión QUIC real por la interfaz de bucle local. Las pruebas de SpectreKit también decodifican barras de color H.264 y HEVC y las dibujan con Metal. Para ejecutarlas en el simulador de iPad:

```bash
(cd Packages/GDPKit && xcodebuild test -scheme GDPKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-GDPKit)
```

```bash
(cd Packages/SpectreKit && xcodebuild test -scheme SpectreKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-SpectreKit)
```

### Sin servidor

Con cualquiera de las opciones siguientes, Spectre se salta el inicio de sesión y empieza a reproducir. Primero codifica con VideoToolbox un flujo de prueba de 10 segundos a 1080p60 (unos 3 segundos) y luego lo repite en bucle. Las estadísticas de decodificación, presentación y sesión aparecen arriba a la izquierda y se imprimen en stdout cada segundo; la barra de herramientas cambia la fuente, el códec y el ritmo de presentación. Hay tres fuentes:

- **Loopback** (la predeterminada): un host de prueba dentro de la app envía el flujo por una sesión GDP real (QUIC en 127.0.0.1). También emite un pitido cada segundo, para probar el sonido.
- **Direct**: el flujo va directamente al decodificador, sin red.
- **Remote**: un wraith iniciado con un token estático (§6.11 de la especificación):

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --connect HOST:PORT --token TOKEN --fingerprint SHA256
```

El modo de rendimiento mide durante N segundos tras 2 segundos de calentamiento, imprime las estadísticas y sale:

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

Otras opciones: `--source loopback|direct`, `--codec h264|h265`, `--mode onArrival|displayLink`, `--in-flight <N, 0 sin límite>`, `--screen <índice de pantalla>`, `--rate <Hz del display link>`, `--min-present-ms <ms>` y `--host-clipboard <texto>` (el portapapeles inicial del host loopback).

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

En iOS la app arranca desde un app delegate de UIKit, para que su controlador de vista raíz pueda bloquear el puntero (véase [docs/input.md](docs/input.md)). Si tienes instalada una compilación anterior a ese cambio, desinstálala una vez con `xcrun simctl uninstall booted org.ghost.spectre.apple`; si no, el sistema restaura la ventana antigua y se queda en negro.

El simulador decodifica el vídeo por software y no informa de `presentedTime`, así que sus tiempos no se pueden comparar con los de un dispositivo o un Mac.

### Estructura del proyecto

| Ruta | Contenido |
|---|---|
| `project.yml` | El proyecto de XcodeGen: un único target de app multiplataforma para macOS e iOS |
| `App/` | La app: puntos de entrada por plataforma, la interfaz de inicio de sesión y de sesión, el icono |
| `Packages/GDPKit/` | El puente en C hacia libgdp (`Native/`) y su capa en Swift: sesiones, lobby, host de prueba |
| `Packages/SpectreKit/` | Código compartido: la sesión, la decodificación con VideoToolbox, la presentación con Metal, la entrada, el flujo de inicio de sesión |
| `scripts/` | Compilan las dependencias y el xcframework |
| `docs/` | Notas de diseño y mediciones, en chino simplificado |
| `experiments/` | Experimentos puntuales, como una prueba de interoperabilidad Swift/C++; no forman parte de la app |
| `third_party/ghost/` | El proyecto ghost original, como submódulo de git de solo lectura |

### Notas de diseño

Las notas de [`docs/`](docs/) explican cómo funciona cada parte, qué se midió y qué problemas surgieron por el camino. Están escritas en chino simplificado.

- [prototype-findings.md](docs/prototype-findings.md): los tres riesgos técnicos del prototipo y cómo se resolvió cada uno (llamar a libgdp desde Swift, presentación sin copias, compilación cruzada para iOS)
- [session-client.md](docs/session-client.md): la capa de sesión, contrastada con los §6–§11 de la especificación
- [login.md](docs/login.md): inicio de sesión en el lobby y confianza en el certificado
- [saved-logins.md](docs/saved-logins.md): contraseñas guardadas en el llavero, inicio de sesión con un toque
- [reconnect.md](docs/reconnect.md): reconexión de una sesión perdida, repetición del inicio de sesión, iOS en segundo plano
- [keep-alive.md](docs/keep-alive.md): keep-alive de QUIC, y cuánto se tarda en detectar una conexión perdida
- [resolution.md](docs/resolution.md): ajustar el escritorio remoto al tamaño de la ventana
- [input.md](docs/input.md): teclado, ratón, cursor y toques
- [keyboard.md](docs/keyboard.md): el teclado en pantalla en iOS, de caracteres a teclas, la barra de teclas
- [audio.md](docs/audio.md): sonido, búfer de fluctuación, decodificación Opus, micrófono
- [clipboard.md](docs/clipboard.md): el portapapeles en el Mac y en iPad, supresión del eco, el aviso de pegar
- [gamepad.md](docs/gamepad.md): mandos, la asignación de botones, el botón Home
- [localization.md](docs/localization.md): los idiomas de la interfaz, el glosario, cómo añadir un texto
- [app-icon.md](docs/app-icon.md): el icono de la app y cómo cambiarlo

## Cómo contribuir

Las incidencias y las pull requests son bienvenidas; para cambios grandes, abre antes una incidencia. Ten en cuenta lo siguiente:

- El cliente está escrito a partir de la especificación de GDP (`third_party/ghost/docs/spec/gdp-spec.md`) y de estándares públicos. La mayor parte del proyecto ghost original es GPL-3.0, así que no copies ni adaptes código de él, incluido su propio cliente spectre; solo `libgdp/` y la especificación son MIT.
- Ejecuta las pruebas de los dos paquetes antes de enviar un cambio, y actualiza la nota correspondiente de `docs/` cuando cambie el comportamiento.
- Los textos nuevos de la interfaz necesitan traducción a todos los idiomas en los String Catalogs; consulta [docs/localization.md](docs/localization.md).

## Agradecimientos

spectre-apple está inspirado en [ghost](https://github.com/jsaiko/ghost), de [Joseph Saiko](https://saiko.dev), un sistema completo de escritorio remoto formado por el protocolo GDP, el host wraith y el cliente spectre para Linux. Este proyecto usa la biblioteca de protocolo de ghost, libgdp, está escrito a partir de la especificación del protocolo y los documentos de diseño publicados por ghost, y toma el nombre Spectre del cliente original. Muchas gracias al autor por publicar ghost como código abierto y por liberar libgdp y la especificación del protocolo bajo la licencia MIT; sin ello este proyecto no existiría.

spectre-apple es un cliente independiente, de terceros, y no forma parte del proyecto ghost.

## Licencia

[MIT](LICENSE).

- En el proyecto ghost original, `libgdp/` y la especificación del protocolo son MIT, y todo lo demás (incluido su propio cliente spectre) es GPL-3.0-only. Este proyecto solo compila `libgdp/`; su código cliente está escrito a partir de la especificación y de estándares públicos, y no copia ni adapta código de las partes GPL.
- La app enlaza estáticamente ngtcp2, OpenSSL, Protocol Buffers, Abseil y zstd, todas con licencias permisivas (MIT, Apache-2.0, BSD-3-Clause). Una distribución binaria debe incluir sus avisos de licencia: véase [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
