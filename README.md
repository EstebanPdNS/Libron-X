<p align="center">
  <img src="https://libron-x.estebanpdn.chatgpt.site/assets/emblem.svg" alt="Logo de Libron-X, diseñado por Esteban" width="160">
</p>

<h1 align="center">Libron-X</h1>

<p align="center"><strong>Una nueva implementación abierta del funcionamiento de Libronix para el estudio bíblico.</strong></p>

<p align="center">
  Ingeniería inversa en curso · Desarrollo nativo para macOS · Proyecto independiente
</p>

<p align="center">
  <a href="https://libron-x.estebanpdn.chatgpt.site">Seguimiento del proyecto</a> ·
  <a href="https://github.com/EstebanPdNS/Libron-X/issues">Preguntas y propuestas</a> ·
  <a href="#estado-actual">Estado actual</a>
</p>

---

## ¿Qué es Libron-X?

**Libron-X —con X— es un proyecto independiente con vocación open source que busca reproducir el funcionamiento que ofrecía Libronix Digital Library System**, el entorno de biblioteca digital y estudio bíblico desarrollado por Logos.

La idea es recuperar esa experiencia mediante una implementación propia: consultar una biblioteca, leer recursos, navegar por pasajes, buscar, relacionar textos y conservar documentos personales de estudio. El trabajo actual se centra en una aplicación nativa de macOS, escrita en Swift, con una interfaz moderna y familiar para quienes utilizaron el programa original.

**Actualmente estoy realizando la ingeniería inversa de Libronix y desarrollando Libron-X a partir de lo que voy comprobando.** El objetivo es entender cómo funcionaban sus formatos, herramientas y recorridos, documentar sus contratos y reconstruirlos de manera verificable.

Este repositorio presenta el proyecto y su dirección. Por ahora contiene únicamente este README: **el código fuente, los ejecutables y los materiales de investigación todavía no se publican aquí**. La apertura del repositorio no equivale a una versión descargable ni a una implementación terminada.

## El programa original y su historia

Libron-X es el nombre de este nuevo proyecto. **Libronix Digital Library System**, también conocido como **Libronix DLS** o **LDLS**, es el programa original que se está estudiando. No deben confundirse los dos nombres.

Según la documentación histórica de Logos, en **2001** se lanzó **Logos Bible Software Series X**, basado en la arquitectura Libronix DLS. En **2006**, Logos Bible Software 3 amplió esa generación de herramientas. Libronix forma parte del legado de Logos; no es un producto creado originalmente por este proyecto. [Historia publicada por Logos](https://www.logos.com/media/mediakit/logos_backgrounder.pdf).

El original ofrecía una biblioteca de recursos relacionados entre sí y funciones de lectura, navegación, búsqueda y estudio. Su manual describe el manejo de bibliotecas, referencias, ventanas y herramientas de consulta. Es una de las fuentes históricas utilizadas para comprender la experiencia que se pretende recuperar. [Guía original de Libronix](https://www.logos.com/media/libronix_quick_start_guide.pdf).

### ¿Por qué recuperar un programa descontinuado?

Libronix pertenece a una generación de software que ya no recibe soporte. El centro de ayuda de Logos lo incluye entre sus aplicaciones **no soportadas**. [Estado de soporte de Logos](https://support.logos.com/hc/es/articles/360007391412-Acerca-de-soporte-gratuito).

En **octubre de 2017**, Logos retiró los servicios web de Libronix, incluidos la activación, las actualizaciones y la sincronización de licencias. Su anuncio también aclaró que ese cierre no desactivaba las instalaciones existentes: podían continuar usándose sin conexión con sus licencias actuales. Por eso, describirlo como descontinuado y sin sus servicios originales es más preciso que afirmar que todas sus instalaciones dejaron de funcionar. [Anuncio oficial de retirada de servicios](https://community.logos.com/discussion/146796/announce-discontinuation-of-libronix-services).

Libron-X nace del interés por conservar y reconstruir sus posibilidades de estudio en un entorno actual, sin depender de que el programa antiguo siga recibiendo mantenimiento.

## Qué se quiere conseguir

El objetivo a largo plazo es reproducir las funciones y recorridos de Libronix para Windows en una aplicación propia para macOS, trabajando con los tipos de biblioteca y documentos que puedan comprenderse y admitirse de forma comprobada.

Las áreas de trabajo incluyen:

| Área | Objetivo |
|---|---|
| Biblioteca | Identificar recursos, consultar metadatos, organizar colecciones y abrir los formatos compatibles. |
| Lectura | Presentar contenido, índices, referencias, enlaces, tablas y gráficos con navegación coherente. |
| Estudio bíblico | Localizar pasajes, relacionar lectores, copiar versículos y comparar textos. |
| Búsqueda | Reconstruir consultas, opciones, rangos y resultados, desde búsqueda básica hasta herramientas especializadas. |
| Documentos personales | Recuperar notas, listas, favoritos, marcadores y espacios de trabajo, conservando su información. |
| Idiomas originales | Investigar griego, hebreo, transliteración, léxicos, morfología y sus relaciones con los recursos. |
| Salida | Preparar copia, vista previa, impresión y exportación con formatos y resultados verificables. |
| Experiencia de uso | Ofrecer ventanas, menús, atajos, preferencias y recuperación de sesiones adecuados para macOS. |

Esta tabla describe el **alcance buscado**. No significa que todas esas funciones estén terminadas o disponibles.

## Estado actual

**Fase: investigación, ingeniería inversa y desarrollo de un prototipo nativo.**

Existe trabajo local de implementación y validación. La documentación de desarrollo, revisada para esta presentación el **14 de octubre de 2026**, registra avances parciales en las siguientes áreas:

| Área | Avance documentado | Límite actual |
|---|---|---|
| Catálogo | Importación e identificación de recursos de una biblioteca local. | Reconocer un archivo no demuestra que todo su contenido pueda leerse. |
| Lector | Lectura de un subconjunto comprobado de artículos LSF, índices, localizador e historial. | La lectura completa de todos los formatos y objetos sigue pendiente. |
| Navegación | Lectores independientes, favoritos, marcadores y enlaces por referencia en casos comprobados. | Falta validar todas las variantes y recorridos del original. |
| Documentos | Notas enriquecidas, listas de referencias e importación de determinados documentos XML. | Anclas, enlaces y propiedades tienen compatibilidad parcial. |
| Espacios de trabajo | Un formato propio para guardar y recuperar parte del estado de la aplicación. | La equivalencia con todas las sesiones originales no está demostrada. |
| Búsqueda | Consultas locales de palabras y frases, operadores y resultados en ámbitos compatibles. | Índices originales, búsqueda especializada y paridad general continúan en desarrollo. |
| Salida del lector | Vista previa y exportación de texto compatible a HTML, TXT, PDF y RTF; integración de impresión. | Tablas, gráficos, tipografía y paginación completas requieren más trabajo. |
| Copiar versículos | Selección de pasajes, estilos, vista previa y salida al portapapeles en casos comprobados. | Continúa la aceptación de estilos, referencias, idiomas y aplicaciones de destino. |

Estos avances proceden de documentación y evidencias locales de desarrollo; **no constituyen una certificación independiente de todas las funciones**. Tampoco implican que haya una release pública o una aplicación lista para uso general.

La equivalencia funcional completa con Libronix sigue abierta. Las guías de estudio, herramientas avanzadas, familias de complementos y compatibilidad integral de recursos necesitan investigación, implementación y pruebas adicionales.

### Plataforma de desarrollo

El prototipo actual se desarrolla en **Swift para macOS**. La configuración local declara macOS 14 o posterior y Swift 6. El trabajo comprobado se concentra en el Mac de desarrollo con Apple Silicon; todavía no se presenta como una matriz de compatibilidad certificada para todas las versiones y arquitecturas.

El original de Windows se utiliza como referencia de comportamiento. No se anuncia por ahora una versión de Libron-X para Windows, Linux o dispositivos móviles.

## Cómo se está realizando la ingeniería inversa

El trabajo combina observación del programa original, análisis de formatos y desarrollo de una implementación propia:

1. **Inventariar el comportamiento:** identificar herramientas, menús, entradas, opciones, salidas y documentos.
2. **Observar recorridos reales:** comprobar qué hace el original, cómo responde a errores y qué conserva al cerrar y volver a abrir.
3. **Analizar estructuras:** estudiar índices, referencias, estilos y formatos sin modificar los archivos originales.
4. **Definir contratos:** distinguir qué se conoce, qué se ha comprobado y qué sigue siendo una hipótesis.
5. **Implementar y comparar:** desarrollar los componentes propios y contrastar sus resultados con los casos de referencia.
6. **Validar conservación y recuperación:** comprobar persistencia, cancelación, integridad y recuperación de documentos.

Una función no se considera equivalente solo porque exista su botón, porque abra un ejemplo o porque una prueba aislada pase. La aceptación requiere comparar entradas, resultados, navegación, errores y persistencia dentro de un alcance explícito.

## Próximos pasos

- Completar la aceptación de Copiar versículos, sus estilos y sus destinos de pegado.
- Ampliar la lectura y presentación de recursos, tablas, gráficos y tipografía.
- Reconstruir referencias, índices y búsquedas con resultados comparables al original.
- Completar documentos personales, herramientas de estudio y restauración de sesiones.
- Mejorar accesibilidad, rendimiento y comportamiento de ventanas y controles.
- Preparar la publicación del código propio, con atribuciones, documentación y pruebas reproducibles.
- Verificar instalación, compatibilidad y distribución antes de ofrecer una versión pública.

El plan se ampliará cuando la investigación revele funciones u opciones que todavía no se han identificado. No hay una fecha de lanzamiento comprometida.

## Seguimiento y participación

El [sitio de seguimiento de Libron-X](https://libron-x.estebanpdn.chatgpt.site) reúne el plan y los estados del trabajo. Sus casillas representan entregables concretos: **el porcentaje de tareas cerradas no mide la equivalencia funcional con el original**.

Puedes utilizar las [issues de este repositorio](https://github.com/EstebanPdNS/Libron-X/issues) para proponer funciones, describir recorridos que recuerdes de Libronix o compartir enlaces a documentación pública. Resultan especialmente útiles las descripciones que indiquen la herramienta, los pasos, las opciones y el resultado esperado.

Mientras no se publique el código, no hay instrucciones públicas de compilación ni un flujo de contribución mediante cambios de código. El repositorio se ampliará cuando se prepare esa etapa.

## Código abierto, bibliotecas y derechos

La intención es publicar **la implementación propia de Libron-X como software open source**. El paquete local de código propio ya declara licencia MIT; su publicación y sus avisos correspondientes se prepararán en la etapa de apertura del código. Este README no publica ese paquete ni concede derechos sobre materiales de terceros.

El proyecto mantiene separados el código propio, el material de investigación y los recursos utilizados como referencia. No se incluyen aquí libros comerciales, bibliotecas privadas, instaladores, ejecutables originales, archivos de licencia ni materiales de desbloqueo. La compatibilidad buscada se refiere a recursos que el usuario tenga derecho a utilizar; no constituye una promesa de acceso a cualquier biblioteca.

La descontinuación del software no convierte sus libros, código, fuentes o marcas en dominio público. Los derechos de Logos y de los respectivos editores y autores permanecen separados de los de Libron-X.

## Identidad y créditos

**Proyecto y diseño del logo: Esteban.**

El nombre del proyecto es **Libron-X**. El emblema mostrado al comienzo corresponde al diseño aprobado para este proyecto y se carga desde su sitio público para mantener este repositorio limitado al README. El diseño del logo tiene una atribución y unas condiciones propias; no se declara bajo MIT por asociación con la futura publicación del código.

Libronix Digital Library System y Logos se mencionan para identificar el software estudiado y su historia. **Libron-X es un proyecto independiente, sin afiliación, patrocinio ni aprobación de Logos.** Las marcas y los materiales del programa original pertenecen a sus respectivos titulares.

## Fuentes históricas

- [Logos Bible Software: Company Background](https://www.logos.com/media/mediakit/logos_backgrounder.pdf): relación entre Logos Bible Software Series X, Libronix DLS y Logos 3.
- [Libronix Quick Start Guide](https://www.logos.com/media/libronix_quick_start_guide.pdf): documentación de la experiencia y las herramientas del original.
- [ANNOUNCE: Discontinuation of Libronix Services](https://community.logos.com/discussion/146796/announce-discontinuation-of-libronix-services): retirada de servicios y continuidad de las instalaciones sin conexión.
- [Centro de ayuda de Logos: Acerca de soporte gratuito](https://support.logos.com/hc/es/articles/360007391412-Acerca-de-soporte-gratuito): clasificación de Libronix DLS como software no soportado.

---

<p align="center"><strong>Libron-X · Recuperar una experiencia de estudio, comprenderla y reconstruirla con código propio.</strong></p>
