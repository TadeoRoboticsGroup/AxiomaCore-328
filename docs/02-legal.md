# Política clean-room y marco legal

**Versión 1.0** · 8 de septiembre de 2026 · **Documento normativo y de obligado cumplimiento**

Toda contribución al proyecto está sujeta a estas reglas. No son recomendaciones.

---

## 1. Por qué este proyecto es legal

### 1.1 Los conjuntos de instrucciones

Un conjunto de instrucciones es una **especificación funcional**: qué hace un opcode, qué flags
altera, cuántos ciclos tarda. Lo que el copyright protege es la *expresión* concreta —el RTL de
Microchip, el texto de la hoja de datos, los layouts físicos—, no la funcionalidad que describe.

Reimplementar la funcionalidad partiendo de documentación pública es una práctica establecida con
precedente industrial de décadas: los clones del 8051, del Z80 y del x86; los BIOS compatibles de
Phoenix y AMI; y, en este mismo nicho, el **LGT8F328P** de LogicGreen, que se vende comercialmente
siendo compatible en instrucciones, registros y pinout con el ATmega328P.

### 1.2 Patentes

Las patentes del núcleo AVR datan de mediados de los años 90; el plazo de veinte años venció. Las
patentes específicas del ATmega328P (2006–2008) están venciendo en esta ventana temporal y cubren
en su mayoría características periféricas, no el ISA.

El riesgo para un proyecto abierto y no comercial es bajo. El proyecto adopta **Apache-2.0**
precisamente por su concesión explícita de patentes. Una comercialización a escala requeriría una
opinión formal de *freedom to operate*; eso queda fuera del alcance actual.

### 1.3 Nombres de registros y bits

`PORTB`, `TCCR1A`, `WGM13` y demás son identificadores funcionales necesarios para la
interoperabilidad: sin ellos, el código existente no compila. Además, ya están disponibles bajo
licencia libre: el fichero `iom328p.h` de **avr-libc es BSD-3-Clause**, de modo que podemos usarlo
directamente con su atribución.

---

## 2. Fuentes permitidas

| Fuente | Licencia | Uso permitido |
|--------|----------|---------------|
| *AVR Instruction Set Manual* (Microchip) | Documento público | Semántica de instrucciones, flags, ciclos |
| Hoja de datos del ATmega328P | Documento público | **Conocer** el mapa de registros y el comportamiento |
| `avr-libc` | BSD-3-Clause | Uso directo de headers, con atribución |
| `avr-gcc` | GPL-3.0 + Runtime Exception | Compilador. La excepción deja el binario libre de la GPL |
| `simavr` | LGPL-2.1 | **Sólo como oráculo de test.** Proceso separado, nunca enlazado |

---

## 3. Prohibiciones

1. **No copiar HDL de terceros** sin auditar la licencia y registrarlo en
   [`LICENSE-EXCEPTIONS.md`](../LICENSE-EXCEPTIONS.md).
2. **No copiar prosa de hojas de datos.** La documentación del proyecto se escribe de cero. Se
   pueden usar los mismos nombres de registro y las mismas tablas de valores —son hechos
   funcionales— pero no las frases que los describen.
3. **No usar marcas de terceros** en el nombre del producto, el logotipo o los nombres de placas.
   Prohibidos: «AVR», «Atmel», «Microchip», «Arduino», «Uno», «Nano», «Mega».
   Permitido el uso descriptivo: *«compatible con el conjunto de instrucciones AVR® de 8 bits»*,
   *«funciona con el Arduino IDE»*, siempre con la nota de marcas registradas.
4. **No reutilizar los signature bytes** del ATmega328P (`0x1E 0x95 0x0F`). El proyecto define los
   suyos y distribuye su propia entrada de `avrdude.conf`. Reutilizarlos haría el dispositivo
   indistinguible de una pieza genuina, que es exactamente el escenario de la falsificación.
5. **No derivar firmware de terceros.** El bootloader se escribe desde cero contra la
   especificación pública del protocolo STK500v1.
6. **No hacer ingeniería inversa** de netlists, layouts ni imágenes de die de dispositivos
   comerciales.

---

## 4. Procedimiento clean-room

1. **Especificar antes de implementar.** El comportamiento se documenta en
   [`01-arquitectura.md`](01-arquitectura.md) con nuestras propias palabras,
   antes de escribir el RTL.
2. **Implementar contra la especificación**, no contra ninguna implementación existente.
3. **Verificar contra un oráculo de comportamiento.** `simavr` se usa como caja negra: se comparan
   estados observables, no se inspecciona su código.
4. **Documentar la procedencia.** Todo fichero RTL lleva una cabecera con autoría y licencia. Todo
   componente de terceros se registra en `LICENSE-EXCEPTIONS.md`.

> **Nota sobre el uso de simavr.** Usar un simulador libre como oráculo de comportamiento es
> equivalente a probar contra el hardware real: se observan entradas y salidas. No se lee, no se
> copia y no se enlaza su código. Esto mantiene la separación clean-room.

---

## 5. Licencias del proyecto

| Artefacto | Licencia | Motivo |
|-----------|----------|--------|
| RTL, testbenches, scripts, firmware | **Apache-2.0** | Concesión explícita de patentes, crítica en hardware. Es la licencia de OpenTitan. |
| Diseño físico y PCB | **CERN-OHL-P v2** | Licencia de hardware permisiva y reconocida internacionalmente. |
| Documentación | **CC-BY-4.0** | Reutilización libre con atribución. |

Ficheros: [`LICENSE`](../LICENSE) · [`NOTICE`](../NOTICE) ·
[`LICENSE-EXCEPTIONS.md`](../LICENSE-EXCEPTIONS.md)

---

## 6. Deuda legal heredada y su resolución

Auditoría del repositorio anterior, con las acciones correctivas.

| Hallazgo | Severidad | Resolución |
|----------|-----------|------------|
| `bootloader/optiboot/optiboot.c` era un derivado de **Optiboot (GPL-2.0)**, con copyright de Bill Westfield y Peter Knight, en un proyecto que se declaraba MIT y Apache a la vez. | Alta | **Eliminado.** Se sustituye por una implementación propia del protocolo STK500v1. Registrado en `LICENSE-EXCEPTIONS.md`. |
| **No existía fichero `LICENSE`.** El README declaraba «MIT» en el texto y «Apache-2.0» en el badge, mientras el bootloader era GPL-2.0. | Alta | **Resuelto.** `LICENSE` (Apache-2.0), `NOTICE` y `LICENSE-EXCEPTIONS.md` añadidos. |
| `arduino_core/axioma/boards.txt` definía placas llamadas «Uno R4» y «Nano Plus», nombres de producto de Arduino. | Media | Renombrar a `AxiomaCore-328 DEV` y `AxiomaCore-328 MINI`. |
| El README afirmaba «production ready», «timing closure achieved» y un área de die de 3,2 mm² sin ninguna corrida que lo respaldase. | Media (reputacional) | **Resuelto.** README reescrito con el estado real y evidencia verificable. |

---

## 7. Lista de comprobación para contribuciones

Antes de abrir un *pull request*:

- [ ] ¿Todo el HDL nuevo es de autoría propia o tiene su licencia registrada en `LICENSE-EXCEPTIONS.md`?
- [ ] ¿La documentación nueva está escrita con palabras propias?
- [ ] ¿No aparece ninguna marca de terceros en nombres de producto, placas o logotipos?
- [ ] ¿Los ficheros nuevos llevan cabecera de autoría y licencia?
- [ ] ¿Se ha consultado alguna implementación de terceros? Si es así, indíquese cuál y bajo qué licencia.

---

> AVR es una marca registrada de Microchip Technology Inc. Arduino es una marca registrada de
> Arduino SA. AxiomaCore-328 es una implementación independiente, sin relación ni respaldo de
> dichas compañías.
>
> **Este documento no es asesoramiento jurídico.** Recoge el análisis técnico y las prácticas del
> proyecto. Para una comercialización a escala, consúltese a un profesional.
