# Contexto para retomar el trabajo

**Última sesión:** 24 de septiembre de 2026 · **fase 3 CERRADA; el `SPM` de verdad abre la fase 4**.
Fase 3 al **100 %** —tareas y las tres cláusulas del criterio—; fase 4 al **20 %**
**Repositorio:** `f43a4e8` **publicado**. Regresión **43/43**, mutación **327** en el catálogo,
cobertura **99,8 %** (3 258 de 3 266), área **8 146 LUT4 / 1 475 FF**
**Sin comitear:** sólo este fichero.

---

## 0duodecies. D14 CERRADA: EL DISPARO AUTOMÁTICO DEL ADC (22-sep)

**Era la última deuda de la fase 3, y lo que la tenía abierta era una dependencia, no una
dificultad**: dos de sus ocho fuentes no existían —el comparador analógico es de esta misma fase—.
Con el comparador dentro se cerró entera.

**Las ocho fuentes de la tabla 23-6, cableadas en `rtl/soc/axioma328_soc.v`** en una tabla donde
**el índice ES el valor de `ADTS`**, para que una fuente mal cableada se vea leyendo una línea.

**Tres cosas que no son obvias:**

1. **El disparo va por el FLANCO de la bandera, no por su nivel.** Las banderas se quedan puestas,
   así que con nivel una comparación del Timer0 encadenaría conversiones para siempre. Y hay un
   caso que sólo sale del flanco: **cambiar `ADTS` a una fuente ya puesta genera un flanco
   positivo**, o sea dispara. Es la hoja de datos, no un efecto lateral.
2. **Son las banderas CRUDAS**, sin la máscara de habilitación: el ADC se dispara con `OCF0A`
   aunque su interrupción esté apagada —muestrear a frecuencia fija sin gastar una ISR por disparo
   es el uso típico—. Por eso Timer0, Timer1, `extint` y el comparador exportan un puerto nuevo
   (`flags_tifr`, `flag_intf0`, `flag_aci`) y **no** se reutiliza la línea del controlador de
   interrupciones. Tres mutantes del catálogo son exactamente ese error.
3. **`OCF0B` y `OCF1A` NO disparan.** Existen y están a un cable, y la tabla 23-6 no las incluye:
   siete fuentes, no nueve. Se declaran sin usar **a propósito y por escrito** para que lint no las
   tape y para que nadie las «arregle».

**LA LECCIÓN NUEVA, y es la del mapa de pines otra vez con otra ropa:** en `axioma_adc` el bus de
disparo **es un puerto**, así que da igual qué haya al otro lado del cable. **Una permutación en la
tabla del SoC —que `OCF0A` y `OCF1B` se crucen— pasa entero el banco de módulo, pasa lint, pasa
síntesis y sale en el chip.** Los cables ENTRE periféricos no los verifica ningún banco de módulo,
por construcción.

Por eso hay un banco nuevo de SoC, `sim/soc/tb_soc_trig.cpp` + `tb_soc_trig_top.v` (`make
sim-trig`, 21 comprobaciones), que provoca **cada fuente por su camino real**: un programa de
verdad se pone `PD2` como salida y la sube para fabricarse su `INT0`, precarga el Timer1 cerca del
final para fabricarse su `TOV1`, mueve `ICP1` para fabricarse su captura. Se mira el pulso del S/H,
que es la prueba observable de que una conversión empezó.

**Y la positiva no basta**: un multiplexor roto de forma que TODO dispare pasaría las siete. Cada
fuente se comprueba **tres veces** —con su `ADTS`, con otro `ADTS` que nadie provoca, y sin
`ADATE`—. Eso es lo que distingue un cable de un cortocircuito. Comprobado por construcción: se
cruzaron dos entradas a mano y el banco cayó con dos fallos.

**Los siete sitios que hay que tocar al añadir un periférico valen también para un BANCO nuevo**:
aquí tocaron la regresión (`REGRESION` en el Makefile), `tools/coverage.py`, la CI y el catálogo de
mutación. Y salió un octavo sitio que no estaba en la lista: **los envoltorios de los bancos de
módulo** (`tb_timer0_top.v`, `tb_timer1_top.v`) fallaron con `PINMISSING` al crecer el puerto del
módulo. Lint lo cazó en `check-all`, no en `make lint`.

---

## 0duodevicies. FASE 3 CERRADA, FASE 4 ABIERTA: EL `SPM` DE VERDAD (24-sep)

**`f43a4e8`.** Cierra la deuda **D2** y con ella **la ultima clausula del criterio de la fase 3**.

**EL CAMBIO DE FONDO: EL NUCLEO YA NO ESCRIBE LA FLASH.** `SPM` pasa de ser una escritura de una
palabra a ser una PETICION: el secuenciador saca un pulso con Z y R1:R0, y lo que ocurra lo decide
`SPMCSR`. Quien escribe es `rtl/periph/axioma_spm.v`, que sabe de paginas, bufer temporal y de los
4,5 ms de la celda. El SoC arbitra el puerto de datos de la Flash con una linea: `spm_ocupado`.

**Tres operaciones**, cada una pedida escribiendo `SPMCSR` y ejecutando `SPM` en los cuatro ciclos
siguientes — **la QUINTA secuencia temporizada del chip, y la unica cuyo segundo paso es una
INSTRUCCION y no una escritura**. `SPMEN` solo llena el bufer; `PGERS` borra; `PGWRT` vuelca y deja
el bufer limpio detras.

**Y LLEGO EL VECTOR 25.** `SPM_READY` es de nivel, como `EE_READY`. `check-docs` dice ya **25 de 25**.

**EL ORACULO NO PUEDE EXISTIR AQUI, y el motivo es bonito:** el arnes diferencial contrasta el RTL
contra simavr ejecutando EL MISMO PROGRAMA, y un programa que se reescribe la Flash cambia ese
programa mientras corre. No es que simavr no lo modele —lo modela—: es que la tecnica no aplica. El
oraculo es el capitulo 26, en dos niveles: `sim-spm` (modulo) y `sim-robust`, que corre la
secuencia ENTERA de un gestor sobre el SoC.

**TRAMPAS PAGADAS EN ESTE PASO:**

1. **El `rjmp` del bucle de espera volvia UNA PALABRA DE MAS** y caia sobre el propio `SPM`, que se
   reejecutaba sin su `SPMCSR`. No daba error: solo salian 5 pulsos donde tenia que haber 4. Se
   encontro instrumentando el SoC con dos salidas de depuracion temporales.
2. **Un mutante quito codigo muerto**: la guarda `!ocupado` al bajar `SPMEN` no podia actuar nunca,
   porque el `SPM` que arranca la operacion YA cierra la ventana.
3. **Otro destapo un hueco del banco**: ningun caso escribia `SPMEN` SIN ejecutar `SPM` detras, que
   es justo cuando la hoja de datos dice que se cae a los cuatro ciclos.

**LO SIGUIENTE DE LA FASE 4**, por orden de dependencia:

1. **El gestor de arranque STK500v1**, <= 512 B, en `fw/`. Con el `SPM` hecho, es software: recibir
   por la USART, decodificar el protocolo y llamar a las tres operaciones. Su criterio es que
   `avrdude` hable con el.
2. **`IVSEL` conectado** — la deuda **D16**, que se desbloquea SOLA en cuanto haya seccion de
   arranque, porque ya esta implementado y verificado en `clkctrl`.
3. `axioma.conf` para avrdude con los bytes de firma, y el paquete de placas del IDE.

---

## 0septdecies. EL BARRIDO SEMANTICO Y LAS DOS CLAUSULAS DEL CRITERIO (23-sep)

Tres commits: `f8ff519` el barrido, `9f10c06` la base de tiempo, `69dc4d6` el I2C.

**EL BARRIDO SEMANTICO (`make sim-bits`): 656 bits en 82 registros — 393 de almacenamiento, 134 con
comportamiento propio, 129 reservados. NINGUNO SIN CLASIFICAR.**

Lo que hace que valga es **de donde sale cada mitad**. Que bits EXISTEN lo genera
`tools/gen_regmap.py` desde avr-libc, el mismo tercero que ya decide las direcciones, y sale a
`sim/soc/regbits.h`. Que hace cada uno se escribe a mano —no hay tercero que lo sepa— y **el banco
falla si un bit que no es almacenamiento llano no lleva motivo escrito**.

**Tres pasadas**, y la tercera no sobra: las dos primeras prueban cada registro DESDE UN REINICIO
LIMPIO —escribir 0xFF en WDTCSR arma el perro y en EECR lanza una grabacion—, y la tercera SATURA
el espacio entero antes de leer. Sin ella se escapan los bits reservados alimentados desde OTRO
registro: un mutante que hacia `EEARH` devolver bits de `EEARL` sobrevivia a las dos primeras.

**Encontro un fallo nuestro** (`PRR` devolvia su bit 4, que no existe) y **corrigio dos
clasificaciones mias**: `MSTR` no es almacenamiento —el hardware lo limpia si `SS` esta bajo— y
`TWDR` tampoco —solo se carga con `TWINT` puesto—.

**Y PILLO AL ORACULO, que es la primera vez.** avr-libc pone los bits de `TWAMR` en 6:0; la hoja de
datos en 7:1. No hace falta creer a ninguno: **en el mismo fichero** avr-libc pone `TWA0..TWA6` en
1:7, y `TWAMR` es la mascara que se aplica A ESA direccion. Una mascara en 6:0 no puede enmascarar
algo que vive en 7:1 — es incoherente consigo misma. El RTL ya estaba bien. La correccion va en el
GENERADOR, no en el banco: quien habla por avr-libc aqui es el generador.

**DOS DE LAS TRES CLAUSULAS DEL CRITERIO DE ACEPTACION, DEMOSTRADAS:**

- **`micros()` no deriva** (`sim-micros`). Se separa **jitter** de **deriva** midiendo DOS ventanas:
  200 periodos dan +13 ciclos y 800 dan **los mismos +13**. No crece, luego es latencia. Y con una
  ISR casi tan larga como el periodo, barriendo su longitud, no se pierde ninguno **mientras
  quepa** —cuando ya no cabe, un AVR de verdad tambien lo pierde: exigirlo seria pedirle al chip
  algo que el original no cumple—.
- **el scanner I2C** (`sim-i2c`). 127 direcciones, una contesta; **con el esclavo mudo, ninguna**.
  El esclavo es el MISMO de `tb_twi`, ahora en `sim/periph/esclavo_i2c.h`. La cascara necesita Y
  CABLEADA de verdad: SDA/SCL son colector abierto y el lazo cerrado de las otras no sirve.

**LA TERCERA NO SE PUEDE CERRAR:** los 25 vectores estan en 24, y el que falta es `SPM_READY`, cuya
fuente es el SPM por paginas de la **fase 4** (deuda D2). La fase 3 queda abierta por eso y **solo**
por eso, y asi esta escrito en el plan y en el README.

**TRAMPAS DEL ENSAMBLADOR A MANO, las tres pagadas:** el opcode de `STS` mal formado
(`0x9300|(r<<4)` no es `0x9200|(r<<4)`); el programa principal creciendo POR ENCIMA de la ISR; y la
mas cara, **dividir por dos la direccion de los vectores** — la tabla de `05-register-map.md` los da
en PALABRAS y su columna se llama asi, y ademas el vector `n` ocupa la palabra `2n` porque el salto
es un `JMP`. Ninguna de las tres da error: el banco simplemente no hace nada.

**VERIFICACION DESDE UN CLON LIMPIO, y encontro algo.** `git clone` + `make check-all` fallaba LOS
CUARENTA Y DOS OBJETIVOS con «No such file or directory»: la regresion escribe el registro de cada
objetivo en `build/` ANTES de que ninguno corra, y en un arbol recien clonado ese directorio no
existe todavia —lo crean los objetivos al compilar—. No rompia nada del chip y por eso ninguna
puerta lo veia, pero es el PRIMER comando que ejecuta un tercero. Arreglado con un `mkdir -p`, y
vuelto a verificar: **42/42 en verde desde el clon**. Merece la pena repetir esta comprobacion cada
vez que se toque el Makefile.

**AUDITORIA DE CIFRAS (24-sep):** se volvieron a medir las del FPGA —bitstream **300 KiB**, `Fmax`
**18,25 MHz** tras rutado, 35,4 % de LUT— y se pusieron al dia las de area, comprobaciones y
mutantes por modulo en el plan, con una nota diciendo que son **las de hoy** y por que se mueven.

---

## 0sedecies. PUD Y PRR: EL CONTROL DE RELOJ, ENTERO (23-sep)

**Paso 4, en dos commits.** `8238085` PUD, `1ca0474` PRR.

**`PUD`** apaga los pull-up de los tres puertos. En el RTL va con una `and` APARTE Y AL FINAL,
porque la hoja de datos lo pone POR ENCIMA de `DDxn` y `PORTxn` —«even if the DDxn and PORTxn
registers are configured to enable the pull-ups»—. Lo que hay que comprobar no es que apague: es
que apague CUANDO LOS OTROS DOS PIDEN LO CONTRARIO.

**`PRR`** es `ce_io & ~prr[n]`, una `and` por modulo — que es lo que el ADR 0003 dijo que saldria
gratis, y salio. **El bit 4 no existe**: la tabla 10-2 tiene siete bits y el hueco esta en medio.

**Los dos tienen banco de SoC propio** (`sim-pud`, `sim-prr`) porque son CABLES ENTRE PERIFERICOS,
y esos no los verifica ningun banco de modulo: alli `pud` y `ce` son puertos. Es la misma leccion
del disparo del ADC, por tercera y cuarta vez. `sim-prr` pone LOS SIETE A MOVERSE A LA VEZ y apaga
uno cada vez, con las dos mitades: el que se apaga se para, y **los otros seis siguen** —sin esa
segunda mitad, atar todo a `~|prr` pasaria entero—.

**FALLO REAL ENCONTRADO, y de los caros:** escribir `ADCSRA = (1<<ADEN)|(1<<ADSC)` —el idioma de
medio Arduino— **no arrancaba ninguna conversion**. La guarda `if (!aden) adsc <= 0` leia el `aden`
GUARDADO, que en esa escritura todavia valia cero, y borraba el `ADSC` recien puesto. Sin error y
sin convertir nunca. La hoja de datos nombra el caso: «or if ADSC is written AT THE SAME TIME as
the ADC is enabled». Arreglado con un `aden_ef`, con caso propio en `tb_adc` y mutante.

**Lo destapo escribir el PROGRAMA del banco de PRR**, no una revision del RTL. Es el argumento
entero de este proyecto en una linea: ningun caso del banco del ADC encendia el ADC de esa forma.

**Dos cosas del arnes que parecian fallos y son la hoja de datos funcionando:** el SPI no daba un
pulso porque PB2 (`SS`) estaba como entrada y con el pad de lazo cerrado se lee CERO, lo que
**limpia `MSTR`** y pasa el SPI a esclavo; y el TWI no arrancaba porque sus lineas sin pull-up se
leen a cero y el maestro ve el bus ocupado. Anotadas en el programa para que nadie las lea como un
apaño.

**LO SIGUIENTE:** el **barrido semantico del mapa de registros**, que es lo unico que queda para
cerrar la fase 3. La idea: para cada bit del mapa, decir si esta IMPLEMENTADO, si es
ALMACENAMIENTO declarado, o si es un hueco — y que eso lo compruebe una puerta, no una lectura.

---

## 0quindecies. EL SUEÑO, Y DOS MUTANTES QUE QUITARON CODIGO (23-sep)

**Paso 3 de clkctrl, y con el la FASE 3 TIENE SUS DIEZ PERIFERICOS.** `SLEEP` sale del
secuenciador como un pulso igual que `WDR` —`retire && d_class == OPC_SLEEP`— y llega a
`clkctrl`, que decide. Sin `SE` es un `NOP`, que es lo que dice la hoja de datos y lo que hace
avr-libc posible (pone `SE`, duerme, y vuelve a quitarlo).

**`make sim-sleep`, cuatro casos, y estan elegidos para demostrar que los dos relojes son DOS:**

| caso | resultado |
|---|---|
| `Idle` + Timer0 | despierta cada **256** ciclos clavados: el temporizador SIGUE |
| sin `SE` | el bucle corre suelto, 10 ciclos |
| `Power-down` + Timer0 | **no despierta nunca** — mismo programa, tres bits distintos |
| `Power-down` + perro | **si**, a los ~200 700: su cuenta no se gatea |

Ninguno necesita ISR: el bit `I` global se deja a cero y despierta la mascara. Con `I` a cero el
chip despierta y sigue por la instruccion de despues del `SLEEP`. Asi el banco no necesita tabla
de vectores.

**DOS MUTANTES SOBREVIVIERON Y QUITARON CODIGO, y es la leccion del paso.** En el paso 2 cualifique
`io_we`, `io_re` y `sleep_pulso` con `ce_cpu`, defendiendo el caso de una escritura congelada
durante el sueño `Idle`. **No puede pasar**: el secuenciador presenta `dm_we` y `dm_re`
REGISTRADOS (ADR 0001), asi que la peticion solo cambia en un ciclo habilitado y al dormirse vale
cero. Era defensa contra algo que la arquitectura ya impide. Quitado, y la razon escrita en el SoC
y en el catalogo para que nadie lo vuelva a poner.

**D17 DECLARADA, y nacio de una frase mia que era falsa.** En el paso 1 escribi que de un
`Power-down` despierta una interrupcion externa de NIVEL. En el chip si —«detected
asynchronously»—, pero aqui el nivel se mira sobre el pin YA SINCRONIZADO y ese sincronizador se
para con `clk_I/O`. No se cierra de paso porque lleva la ruta al pin crudo, que es terreno de D6, y
porque el banco de `extint` modela hoy el nivel sincronizado: cerrarlo cambia el modelo del
oraculo. Va con D6, fase 5.

**El arbol de `docs/00-PLAN.md` §6 estaba obsoleto** y nombraba ficheros que nunca existieron
(`pcint.v`, `iomux.v`, cocotb). Es el fallo de D9 repetido EN UN DIAGRAMA, que es donde
`check-docs` no mira: su comprobacion lee las rutas entre acentos graves, no las de un bloque de
codigo. Reescrito contra la realidad — y la primera version del arbol nuevo nombraba un `synth/`
que tampoco existe, asi que **se comprobo ruta por ruta antes de publicar**.

**LO SIGUIENTE:** el paso 4 de clkctrl —`PUD` a los tres puertos y `PRR` apagando de verdad cada
periferico, que con la habilitacion es una `and` por modulo— y despues **el barrido semantico del
mapa de registros**, que es lo que cierra la fase 3.

---

## 0quaterdecies. EL CHIP ENTERO PASA A HABILITACION DE RELOJ (23-sep)

**ADR 0003, y es la decision de mas alcance de la fase.** `CLKPR` divide y `PRR` apaga, y se hace
con una HABILITACION (`ce`) y no con una puerta sobre el reloj: en la FPGA es la entrada `CE` del
biestable —que ya esta ahi— y en el flujo ASIC es de donde las herramientas DERIVAN las celdas de
puerta de reloj. Escribirla a mano metia un latch, y hay una puerta que falla si aparece uno.

**Dos relojes, no uno:** `ce_cpu` (nucleo, bus, memorias) y `ce_io` (perifericos). Figura 9-1. En
`Idle` el primero se para y el segundo sigue, que es lo que hace util ese modo.

**La red que hace segura la conversion:** con `CLKPS`=0 la habilitacion vale 1 siempre, o sea que
el chip queda **bit a bit** igual. El diferencial dio 20/20 programas y 97/97 mnemonicos a la
primera. Si un modulo se convierte mal, lo dice su propio banco sin tocarlo.

**Y LA MISMA RED ES EL AGUJERO:** un modulo al que se le olvide `ce` pasa su banco, lint, sintesis
y el diferencial, porque todos corren a reloj entero. Por eso existe `make sim-clk`, que baja el
reloj de verdad y mide por el pin. Cuatro patas: el bucle de un programa (nucleo+bus+puerto),
`OC0A` con DOS tomas del prescaler, el bit de arranque de la USART, y el intervalo entre dos
mordiscos del perro guardian —que tiene que salir IGUAL—.

**Tres cosas que el trabajo destapo, y las tres valen para la proxima:**

1. **El generador de baudios de la USART se quedo sin gatear** y ningun banco lo noto. Es
   literalmente el ejemplo que motiva el ADR. Lo cazo `sim-clk` al escribirlo.
2. **Reescribir una cadena `else if` para gatearla es peligroso**: en el ADC se quedo la rama final
   FUERA del bloque, o sea que el prescaler decrementaba justo cuando no debia. Lo cazo el banco
   del ADC. Despues de cualquier reescritura de esas, **auditar que no quede un `else` al mismo
   nivel** —hay un script de eso en el historial de la sesion—.
3. **Las dos tomas del Timer0 no son redundantes**: con `CS`=001 el reloj sale directo de `clk_I/O`
   y NO pasa por el contador compartido. Se quito la habilitacion del prescaler a mano y la medida
   de `CS`=001 seguia pasando.

**El perro guardian y la EEPROM se gatean POR PARTES**, y es lo interesante: la ventana de `WDCE` y
las escrituras de registro van con `ce` —son accesos del programa—, pero LA CUENTA Y EL
VENCIMIENTO NO, porque corren con el oscilador. Un perro que se parase al pararse el reloj del
sistema no serviria para nada: un fallo que pare ese reloj es justo lo que vigila.

**`io_we` e `io_re` van cualificados con `ce_cpu` en el SoC**, y de ahi sale una propiedad util:
todo lo que un periferico hace «al escribirse un registro» ya ocurre una sola vez por ciclo de
sistema sin gatear nada mas. Lo que hay que gatear es el estado que corre SOLO. Esa cualificacion
**no tiene mutante todavia** porque solo es observable con el sueño `Idle` —esta dicho en el RTL y
en el catalogo para que no parezca un olvido—.

**Area:** 7 582 LUT4 y 1 421 FF. Las LUT BAJARON al convertir, porque la habilitacion se mete en la
entrada `CE` del biestable, que es gratis en un slice del ECP5.

**LO SIGUIENTE (paso 3):** el `SLEEP` del secuenciador. Hoy se ejecuta como un `NOP` —esta en
`OPC_NOP, OPC_SLEEP, OPC_WDR, OPC_BREAK`— y hay que sacar un pulso como el de `WDR`, cualificarlo
con `ce_cpu` y llevarlo a `.sleep_pulso()` de `clkctrl`, que hoy esta atado a cero. Con eso entra
el mutante de la cualificacion. Despues, el paso 4: `PUD` a los tres puertos, `PRR` apagando de
verdad cada periferico, y `dormido` a donde haga falta.

---

## 0terdecies. UNA MUTACION CORTADA DEJA UN MUTANTE PUESTO (23-sep)

**Pasó, y es de las trampas caras.** `make mutation` modifica el RTL en sitio y lo restaura al
final. Si el proceso muere sin poder atender la señal —aquí se lo llevó el cierre de la sesión—,
**el árbol se queda con el último mutante dentro**.

Quedó `total = primera ? 50 : 24` en `axioma_adc.v`: una conversión de **12 ciclos donde la tabla
23-1 dice 13**. Y ojo con lo que NO lo vio: **`make lint` pasó limpio**. Es un fallo semántico, de
los que sólo se ven midiendo — el mismo que el banco encontró en septiembre.

**Lo cazó `make mutation-check`**, porque un mutante puesto significa que el texto original que
busca el catálogo ya no está en el fichero. La misma puerta responde a dos preguntas opuestas:
*¿el catálogo sigue apuntando al RTL?* y *¿el RTL sigue siendo el RTL?*.

**El protocolo, para la próxima:**
1. si `mutation-check` se queja del cerrojo `build/.mutation.lock`, comprobar que el pid de dentro
   está muerto (`ps -p <pid>`) ANTES de borrarlo;
2. borrado el cerrojo, **`mutation-check` antes que nada**: los patrones que falten son los
   mutantes que quedaron puestos;
3. restaurarlos a mano desde el catálogo —`sim/mutation.py` tiene el par original/mutante— y volver
   a comprobar.

Está escrito también en `docs/03-verificacion.md`, en la sección de mutación.

---

## 0undecies. LA PUERTA DE LAS DEUDAS (22-sep)

**`e14d465`.** `make check-docs` son ahora **tres** comprobaciones: las rutas que citan los `.md`,
la cuenta de vectores contra `irq_src`, y **que toda deuda citada en el código exista en el
registro**.

**Por qué:** D13 dejó escrito que lo peor de esa deuda era *dónde* estaba escrita —sólo en un
comentario del RTL—. **Cuatro días después** pasó exactamente lo mismo con D15. *Lo que no falla es
lo que se comprueba.*

**Dos detalles del diseño de la puerta, que valen para la siguiente que se escriba:**

- **Se busca la cita, no el número.** `D0` y `D13` son también pines de Arduino en el top de la
  placa; un `\bD[0-9]+\b` a secas los daría por deudas y la puerta sería ruido.
- **Se busca en los dos sentidos**, porque el castellano admite «la deuda D14» y «D1 de la deuda
  técnica». La primera versión sólo miraba uno y se dejaba una cita: *una puerta con un punto ciego
  da una respuesta tranquilizadora, que es peor que no tener puerta*.
- **Y se probó rompiéndola**: se quitó la fila de D15 y la puerta la cazó nombrando fichero y línea.
  Una puerta que no se ha visto fallar no es una puerta.

### LO SIGUIENTE, en orden

1. **`clkctrl.v`** — el **último** de los diez periféricos de la fase 3. `CLKPR` con su secuencia
   temporizada (la **cuarta** del chip, y con vuelta de tuerca: `CLKPCE` se escribe **solo**, con
   los demás bits a cero), `PRR`, `SMCR` y los modos de sueño. **Decidir por escrito** si `PRR`
   corta el reloj de verdad —un `PRUSART0` puesto deja la USART muda, y eso es observable— o si se
   declara deuda; y si se declara, **la puerta nueva obliga a que esté en el registro**.
2. **La deuda D14**, el disparo automático del ADC: falta que los timers y el `extint` exporten sus
   **banderas crudas** —hoy sólo `irq_*`, que es bandera **y** habilitación—.
3. **El barrido semántico del mapa de registros** (Capa 4), que cierra la fase 3.
4. Y con la fase cerrada, **enchufar la placa**: `make prog-ulx3s`.

---

## 0decies. EL REPASO DE LOS `.md` (21-sep) — y lo que enseñó

**`e9bd34f`** repasa los quince documentos contra lo que imprime `make`. Lo que salió:

- **D15 estaba citada en el RTL y no existía en ningún otro sitio.** Un comentario de
  `axioma_eeprom.v` decía «es la deuda D15, declarada en el registro» y el registro no la tenía.
  Es **exactamente** el fallo que documenta D13, repetido **cuatro días después** de escribirlo.
  Ya está declarada: `EERE` no para el núcleo cuatro ciclos, y eso rompe L3.
- **El bitstream llevaba tres periféricos sin rehacerse.**
- El README daba por **pendientes** cuatro periféricos que ya estaban dentro, decía «cinco de sus
  diez» cuando son nueve, y publicaba un 56 % calculado con la fase 3 al 55 %.
- `rtl/fpga/ecp5/README.md` publicaba un **presupuesto** de 3 000–5 000 LUT4 de cuando no había
  bitstream. Son **8 886**: la estimación se quedó corta por casi el doble.

**La lección, que ya va por la tercera vez:** *una cifra que no la imprime un comando se queda
atrás, y nadie avisa*. `check-docs` sólo mira rutas y la cuenta de vectores. Generar la tabla del
README desde los resultados sigue siendo trabajo pendiente.

**Y la regla que sí se puede aplicar ya:** si un comentario del RTL cita una deuda, esa deuda
**tiene que estar en `06-deuda-tecnica.md` en el mismo commit**. No hay puerta que lo compruebe —
podría haberla: buscar `D[0-9]+` en el RTL y exigir que exista la fila.

### LO SIGUIENTE, en orden

1. **`clkctrl.v`** — el **último** de los diez periféricos. `CLKPR` con su secuencia temporizada
   (la **cuarta** del chip, y con vuelta de tuerca: `CLKPCE` se escribe **solo**, con los demás
   bits a cero), `PRR`, `SMCR` y los modos de sueño. **Decidir por escrito** si `PRR` corta el
   reloj de verdad —un `PRUSART0` puesto deja la USART muda, y eso es observable— o si se declara
   deuda.
2. **La deuda D14**, el disparo automático del ADC: falta que los timers y el `extint` exporten sus
   **banderas crudas** —hoy sólo `irq_*`, que es bandera **y** habilitación—.
3. **El barrido semántico del mapa de registros** (Capa 4), que cierra la fase 3.
4. **Una puerta para las deudas citadas en el RTL**, que es barata y hoy no existe.
5. Y con la fase cerrada, **enchufar la placa**: `make prog-ulx3s`.

---

## 0nonies. DÓNDE SE PARÓ (21-sep)

**`374e0c7`** el módulo de la EEPROM, **`d0011b8`** su integración. Con su vector 22, **sólo
`SPM_READY` se queda sin fuente**, y ése es de la fase 4.

### Tres cosas que enseñó, y que valen para lo que viene

1. **`synth-check` paró un fallo antes del commit**, por primera vez: la lectura de la celda era
   combinacional y yosys respondía «replacing memory with list of registers» — 8 192 biestables.
   Con la lectura registrada, **la EEPROM entera cabe en una BRAM**. El lint no lo habría visto.
2. **El banco de extremo a extremo se estaba leyendo a sí mismo.** `hello.c` grababa 0x5A y lo leía
   de vuelta, pero `EEDR` es **el mismo registro** que se usó para escribir: el valor seguía ahí
   aunque la lectura no hiciera nada, y el mutante que corta el oscilador sobrevivía. Ahora el
   programa **ensucia `EEDR` antes de leer**. Es la misma clase de fallo que el lazo realimentado
   del TWI: *una prueba que acierta por el camino equivocado no prueba nada*.
3. **`EE_READY` es de NIVEL**, así que una ISR que sólo cuente **no sale nunca**. El módulo no tiene
   `ack` a propósito.

**Y la lista de la regresión vive ahora en un solo sitio**: `REGRESION` en el `Makefile`, con
`make check-all` para correrla entera. Estaba copiada en el README, en `INSTALL.md` y en la CI.

### LO SIGUIENTE, en orden

1. **`clkctrl.v`** — el **último** de los diez periféricos de la fase 3. `CLKPR` con su propia
   secuencia temporizada (la **cuarta** del chip, y ésta tiene una vuelta de tuerca: hay que
   escribir `CLKPCE` **solo**, con los demás bits a cero), `PRR`, `SMCR` y los modos de sueño.
   **Ojo con `PRR`**: apagar un periférico en el chip le corta el reloj, y eso es visible —un
   `PRUSART0` puesto deja la USART muda—. Decidir si se implementa el corte de verdad o se declara
   deuda, y escribirlo.
2. **La deuda D14**, el disparo automático del ADC: falta que los timers y el `extint` exporten sus
   **banderas crudas** —hoy sólo `irq_*`, que es bandera **y** habilitación—.
3. **El barrido semántico del mapa de registros** (Capa 4), que cierra la fase 3.
4. Y con la fase cerrada, **enchufar la placa**: `make prog-ulx3s` es lo único que le falta a la
   fase 2.

---

## 0octies. DÓNDE SE PARÓ (21-sep)

**`374e0c7`: la EEPROM**, módulo y banco. Falta **integrarla en el SoC** — mismo patrón que con el
ADC y el perro guardián: módulo verificado primero, cableado después.

**Lo que hay que saber de ella:** la **secuencia temporizada** (`EEMPE` y, dentro de cuatro ciclos,
`EEPE`) es ya la tercera del chip; **la celda baja bits y no los sube** —borrar pone `0xFF`,
escribir sin borrar hace un AND—, y por eso hay tres modos y no uno; el **tiempo** son 3,4 ms y
1,8 ms contados con el oscilador que entra de fuera (ADR 0002). Y **`EE_READY` es de NIVEL**: este
módulo **no tiene `ack`**, porque no hay bandera que limpiar.

**La síntesis cazó un fallo antes del commit:** la lectura de la celda era combinacional y yosys
respondía «replacing memory with list of registers» — 8 192 biestables. Con la lectura registrada,
**la EEPROM entera cabe en una BRAM**. Es la primera vez que `synth-check` para algo antes de que
llegara a un commit, y merece la pena recordarlo: el lint no lo habría visto.

Y dos invenciones mías que se corrigieron sobre la marcha: `EEDR` eran **dos** registros —leerlo
tras escribirlo no devolvía lo escrito— y `EEPM` tenía una guarda que la hoja de datos no pone.

### LO SIGUIENTE, en orden

1. **Integrar la EEPROM en el SoC**: los cuatro registros en el mapa, `sel_eeprom` en el banco del
   mapa, el **vector 22** —con eso sólo quedaría `SPM_READY` sin fuente, que es de la fase 4—, el
   oscilador compartido con el perro guardián, y un test diferencial. **Ojo:** `EE_READY` es de
   nivel, así que el programa de prueba tiene que **quitar `EERIE` dentro de la ISR** o se queda
   dentro para siempre.
2. **`clkctrl.v`**: `CLKPR` con su propia secuencia temporizada, `PRR`, `SMCR` y los modos de sueño.
   Es el **último** de los diez periféricos de la fase 3.
3. **La deuda D14**, el disparo automático del ADC: falta que los timers y el `extint` exporten sus
   **banderas crudas** —hoy sólo `irq_*`, que es bandera **y** habilitación—.
4. **El barrido semántico del mapa de registros** (Capa 4), que cierra la fase.

---

## 0septies. DÓNDE SE PARÓ (18-sep)

**`86946fe`** el módulo del perro guardián, **`bfedab6`** su integración.

**Lo que enseñó la integración:** `WDR` ya se decodificaba y el secuenciador la ejecutaba como un
NOP de un ciclo, así que **el núcleo la daba por buena sin que nadie notara si el pulso salía** —
para el núcleo, `WDR` y `NOP` son la misma cosa. Ahora `axioma_seq` exporta el pulso.

**El reinicio sale del SoC** en vez de morderse la cola dentro: en el top de la ULX3S entra en la
cadena de reset junto al botón y al PLL; en los bancos **no**, porque simavr no modela el perro y un
reinicio a media co-simulación rompería el contraste.

**El oscilador entra de fuera** (ADR 0002). En la placa se divide por 97 —128 kHz desde 12,5 MHz—;
en los bancos por 3, porque con el divisor de verdad el periodo más corto son 200 000 ciclos.

### LO SIGUIENTE, en orden

1. **`eeprom.v`**: la máquina de `EECR`, con su secuencia de dos escrituras (`EEMPE` y después
   `EEPE` dentro de cuatro ciclos, igual que el perro guardián) y el vector 22.
2. **`clkctrl.v`**: `CLKPR` con su propia secuencia temporizada, `PRR`, `SMCR` y los modos de sueño.
3. **La deuda D14**, el disparo automático del ADC. Las ocho fuentes ya existen; falta que los
   timers y el `extint` exporten sus **banderas crudas** —hoy sólo exportan `irq_*`, que es bandera
   **y** habilitación—, porque el disparo va por la bandera aunque la interrupción esté apagada.
4. **El barrido semántico del mapa de registros** (Capa 4), que cierra la fase.

Con eso, los 25 vectores tendrían fuente salvo `SPM_READY`, que es de la fase 4.

---

## 0sexies. DÓNDE SE PARÓ (18-sep)

**`86946fe`: el perro guardián**, módulo y banco. **Falta integrarlo en el SoC** — es el mismo
patrón que se siguió con el ADC: primero el módulo verificado, después el cableado.

**Lo que hay que saber de él:** lo importante no es la cuenta sino **la secuencia temporizada**
—`WDCE` y `WDE` a uno a la vez, y el valor dentro de cuatro ciclos—, porque un perro guardián que
se apague con una escritura suelta no sirve para nada. `WDIE` **no** está protegido. Su reloj es
**propio** (128 kHz), y entra como pulso desde fuera por el criterio del ADR 0002. Y el orden de
los bits de `WDTCSR` es **raro a propósito**: `WDP3` en el bit 5, con `WDCE` y `WDE` en medio.

**La mutación cerró dos huecos del banco**: el pulso de reinicio dura un ciclo y hay que mirarlo
**dentro** del avance, y el contador tiene que estar **quieto** con el perro apagado —si sigue
corriendo, el primer vencimiento tras encenderlo llega antes de tiempo—.

### LO SIGUIENTE, en orden

1. **Integrar el WDT en el SoC**: vector 6, el pulso `WDR` desde el secuenciador —hay que mirar si
   `axioma_seq` ya decodifica esa instrucción—, el `wdt_reset` al reset del chip, y el oscilador de
   128 kHz dividido en el top de la placa. Y su entrada en `MAPA[]`, `sel_wdt` en el banco del mapa,
   y un test diferencial que dispare el vector 6.
2. **`eeprom.v`**: la máquina de `EECR`.
3. **`clkctrl.v`**: `CLKPR` con su propia secuencia temporizada, `PRR`, `SMCR`.
4. **La deuda D14**, el disparo automático del ADC. **Las ocho fuentes ya existen todas.** Lo que
   falta es que los timers y el `extint` exporten sus **banderas crudas** —hoy sólo exportan
   `irq_*`, que es bandera **y** habilitación—, porque el disparo va por la bandera aunque su
   interrupción esté deshabilitada.
5. **El barrido semántico del mapa de registros** (Capa 4), que cierra la fase.

**Fase 3: 8 de sus 10 periféricos escritos** —falta EEPROM y clkctrl—, aunque el WDT aún no esté
cableado. **22 de los 25 vectores** disparan.

---

## 0quinquies. DÓNDE SE PARÓ (17-sep, noche)

**Publicado: `ab57835`.** Regresión **31/31**, mutación **233/233**, cobertura **99,6 %**
—2 867 de 2 879 puntos, 19 de 24 módulos al 100 %—, **22 de los 25 vectores** disparan.

**El comparador analógico entró después del ADC**, cortado por el mismo sitio (ADR 0002). Lo que
tiene de particular: **sus dos entradas no son dos pines fijos**. La positiva es `AIN0` o la
referencia interna según `ACBG`; la negativa es `AIN1` o **el canal que elija `ADMUX`** si `ACME`
está puesto **y el ADC apagado** —tabla 22-1—. Ese `ACME` vive en `ADCSRB`, que es del ADC, así que
el SoC cablea los dos periféricos entre sí; y `ACIC` lleva la salida a la captura del Timer1 en
lugar de `ICP1`.

**La mutación encontró un fallo de compatibilidad**: el RTL suprimía la interrupción al apagar el
comparador, y la hoja de datos avisa de lo contrario. El mutante superviviente no señalaba un hueco
del banco — señalaba que **el filtro sobraba**. Es la tercera vez que pasa (MSPIM, ADC, AC): *un
superviviente es una pregunta con tres respuestas — falta banco, falta mirar el pin, o la línea no
hace nada*.

### LO SIGUIENTE, en orden

1. **`wdt.v`**, el perro guardián: oscilador propio de 128 kHz, la **secuencia temporizada** de
   cuatro ciclos para cambiar el prescaler, y los tres modos —reinicio, interrupción, los dos—.
2. **`eeprom.v`**: la máquina de `EECR`, con su secuencia de dos escrituras y sus tiempos.
3. **`clkctrl.v`**: `CLKPR` con su propia secuencia temporizada, `PRR`, `SMCR` y los modos de sueño.
4. **La deuda D14**, ya desbloqueada: el disparo automático del ADC. Las ocho fuentes de `ADTS` ya
   existen todas —la que faltaba era el comparador—, y el módulo está escrito para que sea **una
   condición más en el arranque de la conversión**.
5. **El barrido semántico del mapa de registros** (Capa 4), que cierra la fase.

**Y al hacerlos, acuérdate de las dos reglas que más han cazado aquí:** el catálogo de mutación se
reapunta **en el mismo commit** que mueve el RTL —`make mutation-check` lo dice en un segundo—, y
*si nadie mira el pin, el mapa de pines no está verificado*: el banco propio prueba lo que hace un
periférico, `sim-hello` prueba por dónde sale y `sim-diff` prueba que su vector es el suyo.

---

## 0quater. LO QUE PASÓ EL 17-sep-2026, POR LA TARDE (léelo primero)

**Publicado en `main`: `d8ca7ab`.** El ADC, en tres commits.

| | Qué |
|---|---|
| `6201d12` | **ADR 0002**, comiteado ANTES que una línea de RTL: dónde termina el RTL y empieza lo analógico |
| `763ebdd` | **el módulo** y su banco: 1 561 comprobaciones, 15 mutantes |
| `d8ca7ab` | **dentro del chip**: vector 21, `DIDR0` al puerto, y una conversión de extremo a extremo |

**Certificación:** regresión **30/30**, mutación **223/223**, cobertura **99,6 %**, bitstream
**287 KiB** con **Fmax 18,13 MHz** (margen 1,45×).

### La decisión que no se puede arreglar después

**El RTL es el registro de aproximaciones sucesivas; el DAC y el comparador quedan FUERA**, detrás
de cinco señales. Es el corte de la figura 23-1 de la hoja de datos, y el ADR explica por qué la
alternativa fácil es una trampa: un módulo que reciba el valor ya convertido hace que
`analogRead()` devuelva el número correcto, pasa cualquier banco que mire el resultado y **no es un
ADC**. Es el modelo de simavr con otro nombre — y el de simavr resultó peor de lo esperado:
`avr_adc.c` programa la interrupción a `prescale * 11` ciclos donde el manual dice 13.

Con el comparador fuera, el banco comprueba que el SAR **converge**: las diez decisiones, en orden
de peso, cada una añadiendo su bit y conservando los anteriores.

**El modelo del frente analógico vive en `rtl/fpga/axioma_adc_frente.v`, no en el SoC**, y está
excluido del informe de cobertura a propósito: no es el dispositivo.

### Tres fallos reales que encontró el camino

1. **La conversión duraba 12,5 ciclos de ADC en vez de 13**, porque arrancaba al escribir `ADSC` y
   no en el siguiente flanco del reloj de ADC. El resultado salía bien igualmente.
2. **El vector 21 no lo disparaba nadie.** El mutante que movía el ADC al vector del comparador
   analógico **sobrevivía a la regresión entera**. Lo cierra `sim/diff/tests/adc_irq.S`.
3. **El barrido del mapa de I/O no veía al ADC**: `sel_adc` no estaba en la lista de observación del
   banco, así que sus seis direcciones se reclamaban sin que nadie lo comprobara.

### Y dos trampas que conviene no repetir

- **Sondear `ADSC` en un test diferencial es comparar dos relojes.** El primer `adc_irq.S` hacía lo
  que hace `analogRead()` y divergía en la primera lectura. Lo que sí está en lockstep es el
  **vector**, porque el arnés le levanta a simavr el mismo que tomó el RTL: la espera se hace sobre
  el contador de la ISR, no sobre el periférico.
- **Medir la duración en ciclos de sistema no sirve.** El arranque se alinea al reloj de ADC, así
  que entre la escritura y el comienzo hay un desfase que depende del prescaler; y preguntar por
  `ADSC` mete la latencia del banco encima. La medida que vale es **entre transiciones del DAC**,
  que llevan todas el mismo registro detrás: en las diferencias, el retardo se va.

### LO SIGUIENTE

**El comparador analógico (`ac.v`)**, y por dos razones: es de esta fase, y es lo que **desbloquea
la deuda D14** —el disparo automático del ADC—, porque dos de sus ocho fuentes no existen sin él.
Detrás: el watchdog, la EEPROM y `clkctrl`, y con ellos los **cuatro vectores que siguen sin
fuente**.

Y cuando llegue: **acuérdate de la regla de los pines**. `AIN0` y `AIN1` son PD6 y PD7, `DIDR1` hace
con ellos lo que `DIDR0` con el puerto C, y el banco propio no podrá decir por dónde entran.

---

## 0ter. LO QUE PASÓ EL 17-sep-2026 (léelo primero)

**Todo publicado en `main`: `0eadea2`.** Dos commits, y los dos son de lo mismo: **cuatro fallos de
encaminamiento de pines que sobrevivían a la regresión entera**.

| | Qué |
|---|---|
| `54be62f` | **verif: que XCK sale por PD4 lo dice el pin**, no el banco del periférico |
| `faf8613` | **verif: SDA y SCL también se comprueban en el pin**, y no lo hacía nadie |

**Certificación:** regresión **29/29**, mutación **206/206**, cobertura **99,7 %** —2 662 de 2 671
puntos; el SoC baja de 6 puntos sin cubrir a **3**—.

### Lo que se descubrió, que es lo que hay que recordar

Se inyectaron cuatro mutantes de encaminamiento: `XCK` fuera de PD4; el modo maestro mirando el
`DDR` de otro pin; `SDA` y `SCL` intercambiados; y el TWI adueñándose de dos pines del puerto C que
no son suyos. **Los cuatro sobrevivían.** No era un fallo del RTL: era que **nadie miraba esos
pines**.

Y hay dos motivos distintos, los dos vale la pena tener presentes:

- **El banco de un periférico no ve el SoC.** `tb_usart.cpp` verifica MSPIM contra un esclavo SPI y
  `tb_twi.cpp` contra un bus de colector abierto, pero ninguno de los dos puede decir **por qué pin
  sale** una señal. Sus cifras seguirían pasando enteras con el mapa de pines cruzado.
- **El arnés diferencial realimenta el pad sobre sí mismo**, y un lazo cerrado **se cree cualquier
  cosa**: intercambiar `SDA` y `SCL` es simétrico y pasa sin enterarse.

Lo que mata a los cuatro es `make sim-hello`, que ejecuta firmware de verdad y **decodifica la
línea**. `hello.c` hace ahora dos transacciones más: una **MSPIM** de tres bytes —modo 3, el más
significativo primero— y una del **TWI** —START, `SLA+W` 0xA0 y STOP, lo mismo que
`Wire.beginTransmission()` por dentro—. El banco comprueba `XCK` en **PD4** con **48 flancos
exactos**, los bytes `96 5A C3` por **PD1**, y sobre `SDA`=**PC4** y `SCL`=**PC5** que un START sea
`SDA` bajando con `SCL` alta.

**En el TWI se mira el NIVEL DE LA LÍNEA y no quién conduce** —el banco saca `pc_in`, no `pc_out`—,
que en un colector abierto es lo único que significa algo.

**La regla va por su tercera repetición** —el SPI, `MSPIM` y ahora el TWI—: *si nadie mira el pin,
el mapa de pines no está verificado*. Al añadir un periférico con pines, el banco propio prueba
**lo que hace**; `sim-hello` prueba **por dónde sale**. Está escrito en `docs/03-verificacion.md`.

### Y un detalle que no es del chip, sino de quien lo observa

Al apagar MSPIM **el orden importa**: si se borra `UCSR0C` antes que `UBRR0`, queda una ventana de
dos instrucciones en la que `UMSEL` ya dice «asíncrono» y el divisor sigue siendo el del SPI. El
banco midió ahí un periodo de bit que no existe y no decodificó ni una trama del puerto serie. El
chip no se entera; el analizador lógico de al lado, sí. Primero los pines, después el divisor, y el
modo el último.

### LO SIGUIENTE

Sin cambios respecto de ayer: **el ADC**. SAR de 10 bits con su reloj propio, y el oráculo tendrá
que ser un modelo de comparador escrito desde la hoja de datos, porque simavr entrega el valor de
golpe. Y cuando llegue, **acuérdate de la regla de los pines**: los canales `ADC0..7` son del
puerto C, y el banco propio no podrá decir por cuál entra cada uno.

---

## 0bis. LO QUE PASÓ EL 16-sep-2026

**Todo publicado en `main`: `0af9601`.** Tres commits en dos fusiones.

| | Qué |
|---|---|
| `76800bf` | **periph: el puerto serie vive en PD1 y PD0** — la deuda **D13, cerrada** |
| `904639d` | **docs: nueve cifras del README que ya no eran las que imprime `make`** |
| `0b199d7` | **periph: la USART como maestro SPI** — la deuda **D12, cerrada**, y la puerta `mutation-check` |

**Certificación al cierre:** regresión **29/29**, mutación **202/202**, cobertura **99,6 %**
—17 de 22 módulos al 100 %, 12 puntos adjudicados—, síntesis sin latches, bitstream **286 KiB**
con **Fmax 19,77 MHz** tras el rutado (placa a 12,5; margen 1,58×).

### D13: el puerto serie, y por qué se comprueba EN EL PIN

`TXD` y `RXD` salían del SoC por dos puertos propios. No hizo falta nada nuevo —`axioma_gpio` ya
tenía las dos anulaciones—: con `TXEN0` puesto `PD1` es salida pase lo que pase en `DDRD1`, y con
`RXEN0` puesto `PD0` es entrada pase lo que pase en `DDRD0`, con su pull-up desde `PORTD0`. Son los
**dos únicos pines del puerto D con anulación de DIRECCIÓN**.

**`hello.c` deja `PD0` como salida a propósito** antes de encender la USART y no toca `DDRD1` en
ningún momento, y `tb_soc_uart.cpp` mira `portd_oe` antes y después. Sin esa maniobra, un pin
encaminado y un pin que resulta que vale lo mismo son **indistinguibles**.

Y obligó a tocar el modelo de pad de los bancos: un pin de entrada sin pull-up se modelaba como
cero, y en `PD0` un cero permanente es un **bit de arranque permanente** —el receptor metería
tramas de 0x00 sin parar—. En reposo esa línea vale uno, que es lo que conduce el FTDI.

### D12: MSPIM, y las tres cosas que no se pudieron reutilizar

1. **Sin bit de arranque, la trama la delimita EL RELOJ.** El receptor arranca con el transmisor, y
   la trama muere en el **octavo flanco de salida del pulso**: el único instante que existe con las
   dos fases de `UCPHA` y el único que deja el pin en su reposo.
2. **`XCK` sólo corre mientras hay trama**, y vuelve a su nivel de reposo. Un esclavo SPI cuenta
   flancos y un pulso de más lo descoloca para siempre. **La primera trama salía corrida un bit**
   hasta que se escribió la línea que lo devuelve al reposo, porque el modo síncrono deja el reloj
   donde le pilla y ese uno colgado es un flanco de bajada nada más arrancar.
3. **El dato no pasa por el sincronizador de tres etapas.** En síncrono se lo puede permitir porque
   **el bit de arranque viaja por el mismo retardo y la trama se alinea sola**; aquí no hay
   arranque, y tres ciclos a `f_CPU/2` son bit y medio.

Gratis: `UCPHA` intercambia los dos flancos en vez de duplicar la máquina, y `UDORD` se resuelve
**dando la vuelta al byte** al cargarlo y al guardarlo. Los bits de `UCSR0C` son los mismos
biestables con otro nombre, como en el chip.

**El oráculo es el otro extremo del cable** —un esclavo SPI escrito desde la hoja de datos—, y son
**46 650 comprobaciones**. Doce mutantes nuevos, los doce muertos.

### Tres lecciones del 16-sep que conviene no perder

- **Un mutante que sobrevive no siempre es un fallo del RTL.** Tres `wire` apagaban la paridad, la
  parada y `MPCM` en MSPIM y el mutante que los reactivaba sobrevivía: era **equivalente**, porque
  esas ramas quedan detrás del final de la trama. Se quitaron los tres. Un superviviente es una
  **pregunta** con tres respuestas: falta banco, falta mirar el pin, o la línea no hace nada.
- **«Patrón no encontrado» no es «detectado», y ya van cinco veces.** Ahora hay puerta:
  `make mutation-check` comprueba los 202 patrones **en un segundo**, corre en el trabajo rápido de
  la CI en cada push, y `make mutation` lo hace antes de inyectar nada.
- **El área del SoC no es aditiva ni estable.** Bajó de 8 259 a 7 480 LUT4 *añadiendo* MSPIM: yosys
  aplana y comparte lógica, así que un cambio local mueve el total en cientos. El número atribuible
  es el de **cada módulo por separado** (la USART: 391 → 486). El README ya lo dice.

### Y lo que la documentación afirmaba sin ser verdad

Se auditaron los `.md` contra la salida de `make`. Nueve cifras del README estaban viejas, y
además: `01-arquitectura.md` dibujaba `axioma_eeprom` y `axioma_clkctrl` **dentro del SoC**;
`03-verificacion.md` daba por hechas cinco cosas que no existen —barrido semántico del mapa,
ejecución nocturna, matriz de compatibilidad generada, síntesis para tres familias—;
`04-herramientas.md` abría con `sudo apt install gcc-avr avr-libc`, que **rompe `make
regmap-check`**; el README daba **las fases 2 y 3 por pendientes** tres párrafos después de decir
que la 2 está cumplida, y decía que el SoC corre en tres familias de FPGA cuando `rtl/fpga/gowin/`
y `rtl/fpga/ice40/` están **vacíos**. Todo corregido.

**No hay puerta que compare las cifras del README con la salida de `make`**; `check-docs` sólo mira
que las **rutas** existan. Mientras no la haya, la regla es: **el `make` que cambia una cifra
obliga a revisar el README en el mismo commit.**

### LO SIGUIENTE

**El ADC**, que es el siguiente por valor: lo usa medio mundo con `analogRead` y abre el comparador
analógico detrás. SAR de 10 bits con su reloj propio, y **el oráculo tendrá que ser un modelo de
comparador escrito desde la hoja de datos**, porque simavr entrega el valor de golpe. Detrás: el
comparador analógico, el watchdog, la EEPROM y `clkctrl` — y con ellos los **cinco vectores que
siguen sin fuente**.

Antes de abrir ese frente, la regla del proyecto manda revisar `docs/06-deuda-tecnica.md`: quedan
**D2** (`SPM` sin `SPMCSR`, fase 4), **D6** (sincronizador de una etapa, fase 5), **D10** (Timer2
asíncrono sin dominio propio, fase 5) y **D4, D5, D8, D11** justificadas. **Ninguna es de fase 3.**

---

## 0. LO QUE PASÓ EL 14-sep-2026 (léelo primero)

**Todo publicado en `main`: `2762c07`.** La rama `fase3-twi-y-coherencia` ya está integrada.
Sin comitear queda sólo este fichero.

### Los cinco commits

| | Qué |
|---|---|
| `0779569` | **regmap: los bits por proximidad, no por prefijo.** avr-libc no nombra los bits con el prefijo de su registro —`TWINT` es de `TWCR`, `ADEN` de `ADCSRA`, `DDB0` de `DDRB`, `OCR2BUB` de `ASSR`—, así que se quedaban **sin un solo bit** SPCR, ADCSRA, ADMUX, UCSR0A, TIMSK0, WDTCSR, SPMCSR, EECR, MCUCR, PRR, TWCR, TWSR y los tres DDRx. Y no avisaba: salía un guion. **El nivel L2 promete direcciones Y BITS, y media promesa estaba sin verificar.** 260 → 554 constantes, 30 → 85 registros |
| `93cb5cb` | **regmap: una constante por nombre.** `OCR2_0..7` los define avr-libc dos veces, tras `OCR2A` y tras `OCR2B`, y salían duplicados. No lo cazaba nadie porque **ningún módulo del RTL incluye esa cabecera** |
| `865b1e5` | **la puerta de la cuenta de vectores.** Había tres cifras distintas para lo mismo. El oráculo es `irq_src` del SoC. Corre en `make check-docs` y en la CI |
| `313a4a2` | **el TWI entero** |
| `2762c07` | el merge |

### Lo que hay que saber del TWI

`rtl/periph/axioma_twi.v` · `sim/periph/tb_twi.cpp` (**5 957 comprobaciones**) ·
`sim/diff/tests/twi.S` (**185 entradas a ISR** contra simavr) · **19 mutantes, todos detectados**.

**Es el primer periférico que no es un cable sino un BUS**, y eso manda en el diseño: nadie
conduce nunca una línea hacia arriba. El colector abierto se construye con las DOS anulaciones
que `axioma_gpio` ya tenía —valor atado a cero, dirección modulada— y el pull-up sigue saliendo
de `PORTC`, que es lo que hace funcionar el `digitalWrite(SDA, HIGH)` de `Wire.begin()`.

**SEIS FALLOS REALES que el banco encontró, y ninguno da error con ondas perfectas:**

1. **El arbitraje miraba también el noveno bit mientras transmitíamos.** El ACK legítimo del
   esclavo se leía como pérdida, y el maestro se rendía justo cuando le decían que sí. La hoja
   de datos lo enumera al revés: transmitiendo cuentan los bits 0..7, recibiendo el noveno.
2. **Tras perder el arbitraje seguía conduciendo SDA**, corrompiendo la trama del ganador y la
   suya al leerla. Por eso el 0x68 —«perdí y además me llamaban a mí»— salía como 0x38.
3. **El START pedido era de flanco y no de nivel.** El manejador global corre DESPUÉS del `case`,
   así que el `stop_det` del propio STOP —que llega tarde por el sincronizador— pisaba el START
   recién pedido. El TWI se quedaba parado con TWSTA puesto para siempre.
4. **El semiperiodo se contaba desde que el pin cambia**, no desde que se conduce: 28 ciclos
   donde la fórmula da 20. Un `Wire.begin()` a 100 kHz habría dado 71 kHz.
5. **`S_RETENIDO` forzaba SCL abajo siempre**, así que tras un STOP recibido el chip habría
   bloqueado el bus entero hasta que su ISR contestara.
6. **No había filtro de picos**, y apareció al escribir la deuda D11 con honestidad: se iba a
   afirmar que el sincronizador de dos etapas filtra, y NO filtra, **propaga**. En un bus de dos
   hilos ese pulso no da un bit raro: da un START o un STOP inventado.

### Tres lecciones de la mutación que conviene no perder

- **Un mutante que sobrevive no siempre es un fallo del RTL.** De los tres que sobrevivieron,
  ninguno lo era: uno señalaba que el banco cazaba una **carrera por casualidad de ciclo**
  —arreglado barriendo el retardo entero, porque una carrera no se prueba esperando a tener
  suerte—; otro era un mutante **EQUIVALENTE** y se sustituyó por uno observable; y el tercero
  señalaba **lógica repartida entre dos sitios** —el `case` ponía el estado y el manejador global
  el registro de desplazamiento—, así que romper uno no cambiaba nada. Quitarlo a ciegas rompió
  las cuatro fases de esclavo: ninguno era código muerto y ninguno bastaba solo.
- **Al mover el RTL hay que reapuntar los patrones.** El mutante del mapa de vectores dejó de
  encontrar su texto al partir la concatenación `irq_src`. La mutación lo dice: «patrón no
  encontrado», y eso **no** es lo mismo que «detectado».
- **Un banco que tarda media hora en decir que algo falla no lo ejecuta nadie**, y la mutación lo
  ejecuta diecinueve veces. `tb_twi.cpp` se rinde a los 20 fallos.

### Y después del TWI: la deuda D3, cerrada

`axioma_usart` ya tiene **modo síncrono y MPCM**. **45 313 comprobaciones**, 8 mutantes nuevos.

**El motor de trama es el mismo**, y de ahí que saliera barato: arranque, datos, paridad y parada
se cuentan igual, y lo único que cambia es quién dice «avanza un bit». Con `osr` a uno el contador
de sobremuestreo se agota en el mismo pulso y **la máquina de estados no se tocó**. El orden fue el
que ya salvó el refactor del Timer0: meter la indirección dejando el camino asíncrono idéntico,
correr sus 44 082 comprobaciones como red —la misma cifra exacta, 0 fallos— y sólo después añadir
lo nuevo.

`XCK` es `PD4` y **la dirección la pone el programa**: `DDR_XCK0` elige entre maestro y esclavo, así
que el periférico anula el valor del pin y nunca su dirección — al contrario que el SPI. Y `UCPOL`,
visto desde dentro, es **una inversión del pin**: se trabaja siempre con la misma convención y el
pin lleva el reloj pasado por un XOR, con lo que salen las dos filas de la hoja de datos sin
duplicar media máquina de estados.

**Dos lecciones del banco:**

- **Que el dato llegue NO prueba que `UCPOL` esté bien.** Con los dos extremos equivocados de la
  misma manera la trama sale perfecta. Un mutante que hacía al esclavo ignorar `UCPOL` sobrevivió a
  todo —incluido el tráfico aleatorio con las dos polaridades— hasta que se comprobó **en el
  flanco**: que `TXD` esté quieto alrededor del de muestreo.
- **`RXB8` se lee ANTES que `UDR0`.** Leer `UDR0` saca el byte del búfer y con él su noveno bit. Lo
  destapó el barrido aleatorio; los casos dirigidos tenían el bit 8 a cero y pasaban sin probar
  nada. El RTL ya lo hacía bien: era el banco el que leía al revés.

### DOS DEUDAS NUEVAS, y una de ellas estaba sin registrar

- **D12**: la USART no tenía el modo **SPI maestro** (`UMSEL` = 11). **CERRADA el 16-sep**, en
  `0b199d7` — ver §0bis.
- **D13**: **`TXD` y `RXD` no llegan a `PD1` y `PD0`** — salen del SoC por dos puertos aparte. Un
  programa no puede usar esos pines como E/S general con la USART apagada, la USART no se adueña de
  ellos cuando está encendida, y el pinout no es el del 328P en esos dos pines. **Lo peor es que
  estaba sólo en un comentario del RTL y en ningún documento**, y ese comentario decía que
  enchufarlos era «de la fase 3, igual que la de OC0A/OC0B» — trabajo cerrado el 11-sep. La
  condición que la desbloqueaba llevaba días cumplida y nadie lo sabía, porque la deuda no estaba
  en la lista que se revisa. **CERRADA el 14-sep por la tarde**, en `76800bf` — ver §0bis.

### EL SÉPTIMO SITIO QUE TOCAR AL AÑADIR UN PERIFÉRICO

La regla de §5 dice seis. **Son siete: el banco tiene que ESCRIBIR su fichero de cobertura**
(`VerilatedCov::write` con `AXIOMA_COV`). Sin eso corre entero, pasa entero, y el módulo sale al
65 % porque lo único que lo pisa son los programas del diferencial. Lo destapó la puerta de
cobertura, que bajó de 99,6 % a 95,2 % y falló.

---

## 1. Qué es esto

Microcontrolador de 8 bits, libre y abierto, **compatible a nivel binario con el ATmega328P**.
Herramientas 100 % libres, validación en FPGA, y a largo plazo tape-out en un PDK abierto.

El plan está en `docs/00-PLAN.md`, la arquitectura en `docs/01-arquitectura.md`.
**No los resumas de memoria: léelos.**

| Nivel | Qué garantiza | ¿Objetivo? |
|-------|---------------|-----------|
| L1 | Ejecuta código máquina AVR: 131 instrucciones, SREG exacto | obligatorio |
| L2 | Mismas direcciones y bits; `avr/io.h` funciona tal cual | obligatorio |
| L3 | Misma cuenta de ciclos y temporización de periféricos | sí — **97/97 mnemónicos, y el Timer0 contra su hoja de datos** |
| L4 | 5 V, DIP-28, pinout | no en el die; sí en el módulo |

---

## 2. La regla del proyecto

> **Nada entra sin oráculo. Y el oráculo también se comprueba.**

Un módulo que compila y sintetiza no cuenta como hecho. Cuenta cuando lo contrasta algo
independiente. Y como el modelo de referencia y el RTL los escribe la misma persona, hacen falta
**terceros de verdad**:

| Qué | Oráculo independiente |
|-----|----------------------|
| ALU | `simavr` |
| Decodificador | `avr-objdump` de binutils |
| Núcleo completo | **co-simulación diferencial contra `simavr`** |
| Mapa de registros | el preprocesador de avr-gcc con avr-libc |
| Constraints de la placa | el fichero oficial de la ULX3S |

**No es teoría.** Fallos reales que solo aparecieron gracias a esto:

- Flag H de `NEG` implementado como `R3 | ¬Rd3` cuando el manual dice `R3 | Rd3`. El mismo error
  estaba en el RTL **y** en el modelo, así que se daban la razón mutuamente.
- Desfase de un ciclo en la búsqueda de instrucción: cada instrucción se ejecutaba dos veces.
  Lo cazó el diferencial en la **segunda instrucción del primer programa**.
- `RET` devolvía el byte bajo duplicado (ver §5, regla del flanco).

Y **cinco fallos en los propios bancos de pruebas**, encontrados por la prueba de mutación:
el arnés de memoria no distinguía flanco de subida de bajada; el del banco de registros perdía la
escritura del primer ciclo; y el comparador del decodificador no miraba `alu_op`, ni punteros, ni
direcciones de I/O — con lo que confundir `ADD` con `ADC` pasaba el test.

**Corolario:** `make mutation` es obligatorio, no decorativo.

---

## 3. Estado

**Última certificación completa: 12-sep-2026.** Regresión 27/27, mutación **160/160**, cobertura
**99,7 %**, síntesis sin latches, bitstream reconstruido (276 KB, 29 % de las LUT, Fmax 18,76 MHz).
Cinco commits ese día: los canales PWM al pad, la puerta de rutas de la documentación, la mutación
en la CI, las interrupciones externas, el Timer2 con los seis canales PWM y el SPI. El registro de
deuda técnica **ya está publicado** —dos módulos lo citaban por su ruta, así que la referencia
estaba rota en el repositorio—.

| Fichero | Estado | Evidencia |
|---------|--------|-----------|
| `rtl/core/axioma_alu.v` | verificado | 22 282 240 vectores + simavr + mutantes |
| `rtl/core/axioma_sreg.v` | verificado | 200 029 comprobaciones (dirigidas + modelo sombra) |
| `rtl/core/axioma_regfile.v` | verificado | 800 064 comprobaciones aleatorias |
| `rtl/core/axioma_decode.v` | verificado | 65 536 opcodes × 11 comprobaciones vs objdump |
| `rtl/mem/axioma_progmem.v` | verificado | 34 049 comprobaciones (con el puerto de LPM) |
| `rtl/mem/axioma_dmem.v` | verificado | ídem, incluido el barrido de las 2048 direcciones |
| `rtl/core/axioma_seq.v` | **verificado**, ya con la entrada a ISR | 16 programas dirigidos + 10⁶ aleatorias |
| `rtl/core/axioma_core.v` | **verificado**, ya con la entrada a ISR | ídem; es el que une todo |
| tabla de ciclos (L3) | **verificada** | 300 048 instrucciones contra el manual, 97/97 mnemónicos |
| espacio de datos | **comparado** | barrido de la SRAM entera al final de cada programa |
| `rtl/bus/axioma_dbus.v` | **verificado** | 790 976 comprobaciones sobre las 65 536 direcciones |
| `rtl/periph/axioma_gpio.v` | **verificado** | diferencial + 909 708 comprobaciones por máscara |
| `rtl/periph/axioma_timer0.v` | **verificado** | 4 480 668 comprobaciones en 224 032 ciclos contra la hoja de datos |
| `rtl/periph/axioma_prescaler.v` | **verificado** | ídem; es el contador COMPARTIDO, y va aparte por eso |
| `rtl/periph/axioma_irq.v` | **verificado** | **exhaustivo**: las 67 108 864 combinaciones de las 26 peticiones |
| `rtl/periph/axioma_timer1.v` | **verificado** | 4 475 970 comprobaciones: 16 modos, captura y el TEMP compartido (trampa 4) |
| `rtl/periph/axioma_timer2.v` | **verificado** | 4 666 627 comprobaciones: prescaler PROPIO con /32 y /128, y el asíncrono |
| `rtl/periph/axioma_timer8.v` | **verificado** | el motor de onda de 8 bits, COMÚN al Timer0 y al Timer2; lo ejercitan los dos bancos |
| `rtl/periph/axioma_usart.v` | **verificado** | 46 650 comprobaciones: asíncrono, síncrono, MPCM y **MSPIM**, contra extremos escritos desde la hoja de datos |
| `rtl/periph/axioma_extint.v` | **verificado** | 2 501 159 comprobaciones: los 4 modos de ISC, el nivel bajo y los tres PCINT |
| `rtl/periph/axioma_gpior.v` | **verificado** | GPIOR0/1/2, diferencial + barrido del mapa |
| `rtl/soc/axioma328_soc.v` | **verificado** | las 224 direcciones de I/O por el bus real, sin colisiones |
| `rtl/periph/axioma_spi.v` | **verificado** | maestro y esclavo contra el otro extremo del cable: 4 modos × 2 DORD × 8 divisiones, WCOL, la secuencia de SPIF y la colisión de maestros |
| `rtl/periph/axioma_twi.v` | **verificado** | 5 957 comprobaciones contra un BUS de colector abierto: 26 códigos de estado, las 128 direcciones, TWAMR contra su fórmula, arbitraje, estiramiento, error de bus, periodo de SCL medido y un pico de ruido barrido por toda la trama |
| entrada a ISR | **verificada** | 1 172 entradas contrastadas contra simavr; 4 ciclos, vector, pila, SP y SREG |

```
regresión   29/29 OK   (lint synth-check regmap-check lpf check-docs mutation-check sim-alu
                        sim-sreg sim-regfile sim-mem sim-dbus sim-gpio
                        sim-timer0 sim-timer1 sim-timer2 sim-usart sim-spi
                        sim-twi sim-extint sim-irq sim-soc sim-robust sim-fw
                        sim-hello sim-simavr sim-decode sim-diff sim-random
                        coverage)
            5m00s en total; synth-check es casi todo (sintetiza 14 módulos)
mutación   206/206 detectados · `make mutation-check` verifica los patrones en 1 s
cobertura   99,7 % del RTL (`make coverage`), umbral 99 %. Es PUERTA, no informe
            17 de 22 módulos al 100 %; los 12 puntos restantes, adjudicados
CI         verde, en TRES jobs: lint y ficheros generados · verificación del
            núcleo · MUTACIÓN, que desde el 11-sep también corre en el servidor
síntesis    sin latches · SoC 7 480 LUT4 / 1 216 FF · top de placa 6 804 / 1 220
            el total NO es aditivo: yosys aplana y comparte. La USART: 391 -> 486
bitstream   286 KiB · 32,8 % de las LUT y 58,9 % de la BRAM de la ULX3S 25F
Fmax        19,77 MHz medida TRAS EL RUTADO; corre a 12,5 (margen 1,58x)
```

**Fase 1: COMPLETA, y su deuda saldada.** La entrada a ISR ya se dispara desde el Timer0, y al
hacerlo aparecieron DOS FALLOS REALES (ver §6).

**Porcentaje, medido contra el presupuesto en semanas del propio plan** (1+4+2+5+3+2 = 17 semanas
hasta v1.0 en FPGA; 6-10 más con silicio). Recalculado el 17-sep con los pesos a la vista:
fase 0 → 1,00 · fase 1 → 4,00 · fase 2 al 90 % —falta enchufar la placa— → 1,80 · fase 3 al 55 %
—cinco de sus diez periféricos, más las tres deudas de la USART— → 2,75. Suma **9,55 de 17** →
**~56 % en FPGA**, y **~38 %** contando el silicio con el punto medio de las 6-10 semanas.
**No lo estimes a ojo: recalcúlalo con esa cuenta**, y si cambia el avance de una fase, cambia el
número del README en el mismo commit — el anterior (49 %) se quedó dos periféricos atrás.

### Agujeros conocidos, a 12-sep-2026

Esto es lo que hay que responder cuando pregunte «¿está al 100 %?». NO lo está, y estos son los
huecos de verdad, por orden de lo que duele:

| Hueco | Estado |
|-------|--------|
| **Doble flanco: ACOTADO, ya no bloquea la fase 3** | Sólo `LDS`/`STS` obligan a que el MACRO de SRAM sea de flanco de bajada; el resto presenta la dirección registrada. Los demás flancos de bajada son celdas estándar. Mitigación: cola de prebúsqueda de dos palabras. Adenda 2 del ADR 0001. **El PDK no está instalado: la afirmación sobre los macros de Sky130 sigue sin verificar, y ahí está escrito cómo hacerlo en diez minutos** |
| **Lo que BLOQUEA un tape-out** | Enumerado y medido en `docs/00-PLAN.md`, al final de la fase 2: SPM sin SPMCSR, doble flanco sin macro de SRAM verificado, sincronizador de una etapa sin MTBF, sin formal, sin post-P&R, sin DFT, 7 de 25 vectores sin fuente |
| **Subir el reloj, lo que queda** | De 15,55 a **20,28 MHz** hecho (ver adenda del ADR 0001). El camino que manda son 24,7 ns con sólo 4 de lógica y 14,6 de **rutado**: ya no es profundidad, es distancia. Lo siguiente es sacar el dato de escritura de la SRAM del camino combinacional, y eso obliga a separar los buses de datos de SRAM y de I/O. Objetivo fase 5: 32 MHz |
| ~~Criterio de aceptación de la fase 2~~ | **CUMPLIDO EN SIMULACIÓN 11-sep**, `make sim-hello`: C sin modificar sobre el SoC completo, y el banco decodifica el PIN. Sólo falta enchufar la placa |
| ~~USART~~ | **CERRADA 11-sep.** Modo asíncrono completo. Al hacerla apareció un fallo del BUS que llevaba escondido desde la fase 1 (ver §6) |
| **El diseño cierra timing a 18,76 MHz y se corre a 12,5** | Medida de nextpnr del 12-sep, con Timer2 y SPI dentro; cada periférico nuevo baja un poco el Fmax. Camino crítico de subida a BAJADA: BRAM de programa (5,8 ns clk-a-dato) → decodificador → memoria de datos, todo en MEDIO ciclo. Es el precio del ADR 0001. Margen 1,50x. Objetivo de la fase 5: 32 MHz |
| **El bitstream no se ha probado en la placa** | Se genera, cierra timing y tiene el programa dentro. Falta enchufarla: `make prog-ulx3s` |
| **El pull-up no es dinámico en la FPGA** | En el ECP5 es un atributo estático del bloque de E/S. Coincide con el chip cuando el programa lo activa; el caso contrario la hoja de datos lo deja indefinido |
| ~~No hay top de ECP5~~ · ~~backend y bootstrap~~ | **CERRADO 11-sep.** `axioma_ulx3s_top.v` + `tools/bin2mem.py`: el programa va dentro del bitstream |
| ~~La integración vivía en el banco de pruebas~~ | **CERRADO 11-sep.** `rtl/soc/axioma328_soc.v` es el dispositivo; `make sim-soc` barre las 224 direcciones de I/O por el bus real |
| **9 de los 25 vectores no tienen fuente real** | El controlador está verificado exhaustivamente. Ya disparan los tres del Timer0, los cuatro del Timer1, los tres del Timer2, los tres de la USART, el del SPI y los cinco externos (INT0/1 y PCINT0/1/2). Faltan TWI, ADC, comparador, watchdog, EEPROM y los dos del bootloader |
| **Capa 6, formal: sin empezar** | `sby` está instalado; no hay ni un `.sby`. `sim/tb`, `sim/golden` y `sim/cocotb` están vacíos |
| ~~`make sim-isa` es un stub que sale con error~~ | **CERRADO 11-sep.** Objetivo retirado: lo cubren `sim-diff` y `sim-random` |
| ~~La mutación no está en la CI~~ | **CERRADO 11-sep.** Job aparte —no un paso de `verify`— para que sus 8 minutos no retrasen la señal del resto ni se confunda un catálogo obsoleto con un fallo del RTL |
| **Regresión aleatoria: 10⁶, y el criterio de v1.0 son 10⁷** | Es de la fase 5, pero conviene no olvidarlo |
| **`SPM` no es el del 328P** | Lo que hay —escribir una palabra— está verificado en `make sim-robust`, `SPM Z+` incluido. Lo que falta es `SPMCSR` y la granularidad de página: sin eso no hay bootloader. Es la deuda D2, fase 4 |
| ~~Sin medida de cobertura de código~~ | **CERRADO 11-sep.** `make coverage` fusiona todas las fuentes con LCOV y es una PUERTA, no un informe |

### La deuda técnica tiene su propio documento

`docs/06-deuda-tecnica.md`, **y se mantiene al día en el mismo commit que crea la deuda**. La tabla
de arriba son los HUECOS —lo que falta por hacer—; la deuda es otra cosa: **RTL que existe, que se
sintetiza y que va a acabar en silicio, pero que no hace todo lo que su nombre promete**. Mezclar
las dos listas es la forma más fácil de que algo a medias llegue a una foundry.

La regla, que el usuario pidió el 11-sep y que se queda: **antes de abrir un frente nuevo se revisa
esa lista y se cierra lo que se pueda cerrar. Lo que no, se justifica por escrito con qué lo
desbloquea.** Una deuda justificada es una decisión; una deuda olvidada es una sorpresa en la oblea.

A 12-sep hay **diez** apuntadas: D1 (canales OC al pad), D7 (`sim-isa`) y D9 (rutas muertas en la
documentación) **cerradas el 11-sep**; D10 (el Timer2 asíncrono sin dominio de reloj propio, con los
cinco bits de ocupado de `ASSR` leyéndose a cero) nace con el Timer2 y espera a la fase 5, porque
cerrarla es lógica entre dominios y eso no se cierra sin formal; D2 (`SPM` sin `SPMCSR`) espera a la fase 4, D3 (USART
síncrona y `MPCM`) a la fase 3 y D6 (sincronizador de una etapa sin MTBF) a la fase 5; D4, D5 y D8
están justificadas. Al cerrar D9 quedó una puerta nueva, `make check-docs`, que comprueba que las
rutas del repositorio citadas en los `.md` existan — la CI ya validaba los enlaces de Markdown, que
son sólo la mitad de las referencias.

### El motor de 8 bits vive UNA VEZ, y hay que mantenerlo así

`axioma_timer8.v` es la máquina de forma de onda del Timer0 **y** del Timer2, porque la hoja de
datos las describe con las mismas palabras. Su modelo de referencia también: `sim/periph/timer8_ref.h`,
que usan los dos bancos. Lo de fuera —direcciones, selector de reloj, prescaler, `ASSR`— sí es de
cada uno.

**Si alguien vuelve a copiarlo en dos ficheros, la mutación lo dice en el mismo commit:** siete
mutantes del grupo `timer0` se inyectan en `axioma_timer8.v` y los caza `sim-timer0`, y el del doble
búfer del grupo `timer2` se inyecta en el MISMO fichero y lo caza `sim-timer2`. Con el motor
duplicado, la mitad dejaría de aplicarse.

El refactor se hizo con el banco del Timer0 **sin tocar**: sus 4 480 668 comprobaciones son la red.
Ése es el orden correcto —extraer, correr el banco viejo, y sólo después refactorizar el banco—, y
aun así la mutación cazó siete patrones desincronizados. Es la cuarta vez que pasa; el catálogo se
actualiza SIEMPRE en el mismo commit que mueve el RTL.

### D6 tiene ahora DOS sitios donde mirar

El sincronizador de una etapa ya no vive sólo en `axioma_gpio`: `axioma_extint` lleva el suyo, con
el mismo criterio y el mismo motivo —es lo que fija la temporización documentada—. Cuando en la
fase 5 se decida meter la segunda etapa contra la metaestabilidad, hay que tocar **los dos** y
volver a medir el `nop` documentado. Está escrito en la cabecera de los dos módulos.

---

## 4. LO SIGUIENTE

1. ~~**Suite dirigida de las 131 instrucciones.**~~ **HECHA.** Ocho programas en
   `sim/diff/tests/`: `basic`, `flow`, `gpio`, `mem`, `isa_bits`, `isa_branch`, `isa_lpm` e
   `isa_system`. Cubren los **97 mnemónicos** ejecutables del 328P. `SPM` queda fuera a propósito.
   El noveno, `irq_timer0`, llegó con las interrupciones.

1bis. ~~**Regresión aleatoria de 10⁶ instrucciones.**~~ **HECHA.** `sim/random/gen_random.py` +
   `make sim-random`: 10 programas × 100 000 instrucciones, semilla fija, 0 divergencias. Con esto
   la fase 1 cumple su criterio de aceptación completo.
2. ~~**Tabla de ciclos (nivel L3).**~~ **HECHO.** El arnés contrasta los ciclos de cada
   instrucción retirada contra la tabla del manual, que vive como fichero de datos en
   `sim/perf/cycles_ref.py` y se proyecta sobre los 65 536 opcodes con el mnemónico de
   `avr-objdump`. Encontró un fallo real: `MOVW` costaba 2 ciclos donde el manual dice 1.
   **Cerrado: 97/97 mnemónicos**, 300 048 instrucciones, 0 desviaciones.
2bis. **FASE 2 EN MARCHA.** `rtl/bus/axioma_dbus.v` está hecho y verificado. Lo que enchufa en él:
   ~~`gpio.v`~~ **hecho**, ~~`timer0.v`~~ **hecho**, ~~`irq.v`~~ **hecho**; quedan `usart.v`, el
   top de ECP5 y el backend `fpga_bram`. Objetivo de la fase: un LED parpadeando en la placa.

   **EL ORÁCULO DE LOS PERIFÉRICOS YA ESTÁ DECIDIDO Y ESTRENADO CON EL GPIO.** Va por capas:
   - **semántica de registros** → diferencial contra simavr, con la tabla `COMPARABLE[]` de
     `sim/diff/diff.cpp`, que crece con cada periférico que aterriza;
   - **lo que simavr NO modela** → banco propio contra la hoja de datos (`sim/periph/tb_gpio.cpp`).

   Con el GPIO aparecieron tres diferencias entre simavr y el chip, y en dos manda el chip:
   el sincronizador de `PINx` (simavr no lo tiene: el mutante que lo elimina SOLO lo caza el banco
   propio), el enmascarado de PC7 (simavr no enmascara; por eso el banco se corre con las dos
   máscaras) y el pull-up apagado en un pin de entrada, que es un caso **indefinido** y del que
   ningún programa debe depender. **Espera lo mismo de cada periférico: mira el modelo de simavr
   ANTES de escribir el RTL.**

3. ~~**`timer0.v` + `irq.v` COMO UN BLOQUE.**~~ **HECHO, y con ello la deuda de la fase 1.**

   - `rtl/periph/axioma_prescaler.v` — el contador de 10 bits LIBRE y COMPARTIDO, más `GTCCR`.
     Va aparte del temporizador justo porque es compartido: en la fase 3 el Timer1 se engancha al
     MISMO contador. Es la trampa nº 12.
   - `rtl/periph/axioma_timer0.v` — los ocho modos de onda, doble búfer de `OCR0x`, `TIFR0` con su
     *write-1-to-clear*, reloj externo por T0 y los pines OC0A/OC0B. **El encaminamiento de esos
     pines al pad es de la fase 3**, con el resto de los canales PWM: hace falta darle a
     `axioma_gpio` una entrada de anulación. La lógica que los genera SÍ está verificada.
   - `rtl/periph/axioma_irq.v` — 26 vectores, prioridad fija, reconocimiento que limpia la bandera
     en su origen. Verificado EXHAUSTIVAMENTE: 67 108 864 combinaciones.
   - `sim/diff/tests/irq_timer0.S` — enciende los tres vectores del Timer0 a la vez.

4. ~~**Interrupciones — el detalle.**~~ **HECHO.** `irq_req` ya no está atado a 0. Al ejercitar por
   fin esa ruta aparecieron **dos fallos reales**, los dos en `axioma_seq.v` (ver §6).

5. ~~**Top de ECP5 + bitstream.**~~ **HECHO.** `make bitstream-ulx3s` da 248 KB. El reloj es de
   **12,5 MHz** y no de 16: el PLL del ECP5 no puede sacar 16 exactos de 25 —16/25 obliga a un
   divisor múltiplo de 25 y el comparador de fase se queda por debajo de su mínimo— y además a
   15,625 MHz **el diseño no cierra timing**. Lo que importa es que sea EXACTO: el firmware se
   compila con `F_CPU=12500000` y la cuenta no deriva.

   `fw/blink/blink.c` se compila con avr-gcc y avr-libc **sin tocar nada** y pasa el diferencial:
   50 000 instrucciones, 0 divergencias, 4 entradas a ISR. Es `make sim-fw`.

6. ~~**`usart.v`**~~ **HECHA.** Modo asíncrono completo, con banco propio que decodifica el pin
   porque simavr no modela el cable. 44 082 comprobaciones.

8. **FASE 3, lo que lleva hecho y lo que queda.** Hechos y comiteados, cada uno con banco propio
   contra la hoja de datos, mutantes, entrada en `MAPA[]` de `sim/soc/tb_soc_map.cpp` y su vector
   disparado de verdad desde un programa: ~~`timer1`~~, ~~`extint`/`pcint`~~, ~~`timer2`~~ —y con
   él los seis canales PWM llegando al pad—.

   **Quedan: ADC, comparador analógico, watchdog, EEPROM y `clkctrl`.** Son **5** de los 25
   vectores sin fuente —WDT, ADC, EE_READY, ANALOG_COMP y SPM_READY—, y esa cuenta ya no se
   puede quedar atrás: la comprueba `make check-docs` contra `irq_src`.

   **El siguiente por valor es el ADC**, que es el otro que usa medio mundo (`analogRead`) y el
   que trae 6 de los 25 vectores... no: trae uno, pero abre el comparador analógico detrás. Lo
   suyo es un SAR de 10 bits con su reloj propio, y el oráculo tendrá que ser un modelo de
   comparador escrito desde la hoja de datos, porque simavr entrega el valor de golpe.

   **Y antes, la deuda D3** —USART síncrona y MPCM—, que está justificada por escrito pero sigue
   siendo de la fase 3, y ahora es barata: el registro de desplazamiento con muestreo y cambio en
   flancos opuestos ya está escrito dos veces, en `axioma_spi` y en la capa de bit del TWI.

   **EL SPI ESTÁ CERRADO** (12-sep). Lo que dejó, y que conviene no perder:

   - `axioma_gpio` tiene ahora **anulación de DIRECCIÓN** (`dir_ovr_en` / `dir_ovr_val`) además de
     la de valor, porque la tabla 18-1 **sí** fuerza la dirección de los pines del SPI —«this pin
     is configured as an input regardless of the setting of DDB2»— mientras que los canales de
     comparación no la fuerzan nunca. Son dos mecanismos y hay que tenerlos separados: con uno
     solo, o un `analogWrite()` sin `pinMode()` funcionaría —y en el chip no—, o un esclavo con
     `DDB4` mal puesto cortocircuitaría contra el maestro.
   - **El banco encontró TRES fallos reales en el RTL**, y ninguno daba error: el maestro
     muestreaba `MISO` por el sincronizador de dos etapas —a `fosc/4` eso es un bit entero—; el
     reloj se cortaba medio periodo antes de volver al reposo; y `SPIF` se levantaba con ese medio
     periodo por delante, con lo que `while(!(SPSR&(1<<SPIF))); SPDR = siguiente;` se llevaba un
     `WCOL`. Los tres son mutantes ahora.
   - **Y un cuarto, de compatibilidad:** la colisión de maestros sólo aplica si `SS` es ENTRADA.
     Sin eso, el `digitalWrite(SS, LOW)` de cualquier sketch borraba `MSTR`. El módulo recibe
     `ss_es_salida` del SoC —que es `pb_oe[2]`— para saberlo.
   - **Cuatro mutantes sobrevivieron la primera vez** y cada uno señalaba un hueco del banco:
     faltaba medir CUÁNTO DURA una transferencia entera (no sólo el periodo de SCK), que un
     esclavo sin seleccionar suelte `MISO`, y que el pin de `MOSI` sea de verdad el que sale al
     pad. Lo último obligó a que `hello.c` hiciera una transacción de arranque y que
     `tb_soc_uart.cpp` la decodificara del PIN. **Esa es la lección que se repite: si nadie mira
     el pin, el mapa de pines no está verificado.**

   Detrás del SPI, por orden de valor: (b) verificación formal, que sigue a cero y es el bloqueo de
   tape-out más barato de empezar; (c) la cola de prebúsqueda, que arregla el doble flanco Y el
   camino crítico a la vez.

**Añadir un programa de prueba es trivial:** un `.S` en `sim/diff/tests/` y `make sim-diff` lo
recoge solo. Trae gratis la comprobación de ciclos, el barrido de memoria y la cuenta de
cobertura.

---

## 5. Decisiones tomadas — no las revuelvas

**Memoria de DATOS en flanco de bajada; la de PROGRAMA en flanco de subida.**
Razonamiento en `docs/adr/0001-memorias-en-flanco-de-bajada.md`.

> **REGLA QUE HAY QUE TENER PRESENTE AL ESCRIBIR EL SECUENCIADOR:**
> con la memoria de datos en flanco de bajada, **una lectura lanzada en el ciclo N está lista para
> registrarse en el flanco de subida que CIERRA ese mismo ciclo N**, no en el siguiente.
> Escribir un caso como si la memoria fuera de flanco de subida —consumir la lectura anterior
> mientras se lanza otra— captura la lectura NUEVA, porque el dato cambia a mitad de ciclo.
> Fue el fallo de `RET`. Ya están revisados `LD`, `POP`, `LDS`, `IN`, `SBI` y `CBI`.

**La dirección de búsqueda es `next_fpc`, el valor combinacional, no el registrado.** Con el
registrado va un ciclo atrasado y cada instrucción se ejecuta dos veces.

**El secuenciador tiene un ciclo de calentamiento (`warmup`) tras el reset**, porque la memoria de
programa está registrada y en el primer ciclo todavía no ha llegado `mem[0]`.

**El decodificador emite una clase de operación**, no banderas sueltas que puedan quedar
incoherentes entre sí.

**El banco de registros direcciona el puerto de 16 bits por ÍNDICE DE PAR**, para que la interfaz
no pueda expresar una dirección impar. Tiene cuatro puertos de lectura: Rd, Rr, espacio de datos
(`ds_`) y depuración (`dbg_`).

**El par que se LEE y el que se ESCRIBE en el puerto de 16 bits son independientes** (`a16_pair` y
`w16_pair`). Es lo que permite que `MOVW` copie de un par a otro en UN ciclo, como manda el manual.
Con un índice compartido hacían falta dos, y el estado salía correcto: sólo lo veía la
comprobación de ciclos. Todas las demás clases pasan el mismo par a los dos puertos.

**`axioma_core` intercepta tres direcciones** que no pueden salir al bus porque su estado vive
dentro: `0x5D` SPL, `0x5E` SPH y `0x5F` SREG. El arranque de avr-gcc hace `out SPL,r28`, así que
sin esto ningún programa real monta su pila.

**El mapa de registros generado tampoco lleva guarda** desde el 9-sep-2026, por el mismo motivo.
La llevaba, y habría dejado sin constantes al segundo módulo de la fase 2 que la incluyera.

**Las cabeceras `.vh` de constantes NO llevan guarda de inclusión**: se incluyen dentro del cuerpo
de cada módulo y con guarda el segundo se queda sin constantes.

**EL DISEÑO ES `rtl/soc/axioma328_soc.v`.** Ahí vive el mapa de direcciones de I/O y el de los 26
vectores. `sim/diff/axioma_sim_top.v` es sólo una cáscara con lo que un chip no tiene: el modelo de
pad, la carga del programa por referencia jerárquica (`soc.pm.mem[...]`, porque el 328P no tiene un
puerto para que le escriban la Flash) y las tomas de observación. Si añades un periférico, va en el
SoC **y** en la tabla `MAPA[]` de `sim/soc/tb_soc_map.cpp`, que está escrita desde la hoja de datos.

**El espacio de I/O NO es RAM.** Una dirección sin implementar se lee como `0x00`. Hubo un array en
el banco que fingía lo contrario y hacía que el artefacto verificado y el dispositivo no fueran el
mismo. No lo vuelvas a meter: si un test necesita almacenamiento, los tres GPIOR son registros de
verdad del chip y están implementados.

**Ficheros generados, nunca escritos a mano:**
`rtl/soc/axioma_regmap.vh` y `docs/05-register-map.md` ← `tools/gen_regmap.py`;
`rtl/fpga/ecp5/axioma_ulx3s.lpf` ← `tools/gen_ulx3s_lpf.py`;
`images/*.png` ← `tools/gen_diagrams.py` (`make diagrams`).

**LAS FIGURAS DEL README SE QUEDAN ATRÁS Y NO AVISAN.** El estado de cada bloque está escrito a
mano en `tools/gen_diagrams.py` (`OK`, `PARTIAL`, `TODO`), y los números de la figura de
verificación también. Cuando cambie el estado de un módulo, **regenera y míralas**: el 11-sep-2026
el diagrama pintaba `dbus`, `gpio` e `irq` como pendientes justo encima de la tabla del README que
los daba por verificados. Es el mismo fallo que la regla de los `.md`, pero en PNG.

**LAS FIGURAS SON TRANSPARENTES ENTERAS, no sólo el margen.** El lienzo de cairo es ARGB32 y se
deja sin pintar, y además **todos los rellenos son lavados translúcidos**: la placa oscurece un
punto, el panel aclara, y el tinte de estado apenas tiñe. Cada capa se compone sobre lo que haya
debajo —la página—, así que la figura conserva su jerarquía sobre cualquier color de fondo y no
sólo sobre el blanco exacto que suponía la paleta.

En la paleta **ya no hay un color `bg`**: se partió en dos cosas que nunca fueron la misma.
`panel` es el lavado translúcido de los bloques que parecen recortados sobre la placa, y `chip_ink`
es la tinta OPACA del texto que va encima de una etiqueta de color —la píldora «ORÁCULO», los
círculos numerados—. Tintas, trazos y la barra de estado de cada bloque siguen opacos: son lo que
hay que leer.

**Con los rellenos convertidos en lavados, el que dibuja las tarjetas es el BORDE**, así que lleva
contraste de verdad y dos pesos: `line_strong` para la plancha que lo envuelve todo —y con
`lw=1.6`— y `line` para las tarjetas de dentro. Los dos translúcidos, por lo mismo que los
rellenos. Si vuelves a bajarles el alfa, los recuadros se deshacen.

Los alfas se multiplican al apilarse (tinte de estado sobre panel sobre placa sobre página), y
están elegidos para que la suma dé aproximadamente los colores planos de GitHub. Si los tocas,
**míralo compuesto sobre varios fondos**, no sólo sobre blanco.

Siguen haciendo falta las dos variantes, clara y oscura: la transparencia quita el rectángulo, pero
el texto de la clara es oscuro y sobre una página oscura no se leería.

**FPGA: ULX3S 25F** (ECP5). Constraints generadas y verificadas, 36 pines.

**HABILITA UNA SOLA INTERRUPCIÓN CADA VEZ EN LOS TESTS DIFERENCIALES.** Con varias puestas a la
vez, **intercambiar dos vectores del mismo periférico es INVISIBLE**: el arnés le dice a simavr cuál
tomó el RTL, así que no puede desmentirlo mientras la habilitación esté puesta. No es una sospecha —
se inyectó ese fallo exacto como mutante y sobrevivía a todo el banco. `timer1_irq.S` rota la fase
cada 16 vueltas para que cada vector se ejercite solo. **Haz lo mismo con cada periférico nuevo.**

**AL ESCRIBIR UN MODELO DE REFERENCIA, CUIDADO CON BLOQUEANTE FRENTE A NO BLOQUEANTE.** Es el error
que más veces he cometido en este proyecto: cuatro veces ya —el sentido de la cuenta en el Timer0, y
en el Timer1 la captura, el cancelador de ruido y el TEMP—. El RTL usa `<=` y todo ve los valores
DE ENTRADA al flanco; un modelo en C con `=` ve los ya actualizados. Guarda los valores previos al
principio de `cycle()` y úsalos.

**SI AÑADES UN PERIFÉRICO, HAY SEIS SITIOS QUE TOCAR**, y olvidar uno no da error, da un test que
pasa sin probar nada: el SoC, la tabla `MAPA[]` de `sim/soc/tb_soc_map.cpp`, la ventana
`dbg_periph` de `sim/diff/axioma_sim_top.v`, `tools/synth_check.py`, `tools/coverage.py` y
`.github/workflows/ci.yml`.

**LA COBERTURA ES LA ÚNICA QUE DICE LO QUE NO SE HA PROBADO.** «0 divergencias» no dice nada sobre
lo que no se ejecutó, y el catálogo de mutación lo escribe una persona: sólo prueba lo que a alguien
se le ocurrió romper. `make coverage` fusiona TODAS las fuentes —medir sólo el diferencial da 80 % y
una conclusión falsa— y tiene umbral. Su primera ejecución encontró cuatro caminos que ningún banco
pisaba: `SPM` (con TRES fallos dentro), la ejecución de un opcode ilegal, los tres vectores de la
USART, y dos puertos de escritura de SREG que eran lógica muerta. **Si añades RTL, mira la
cobertura antes de darlo por hecho.**

**EL ARNÉS MANDA SOBRE simavr EN LAS INTERRUPCIONES, Y HAY QUE IMPONERLO.** simavr levanta
interrupciones por su cuenta —su USART pone UDRE sola— y se iría al vector una instrucción antes que
el RTL. `diff.cpp` le limpia lo pendiente antes de darle el vector, y **insiste hasta que lo
atiende**, porque limpiar `pending` no vacía su cola interna.

**LA PETICIÓN A LA MEMORIA DE DATOS VA REGISTRADA.** La dirección, el control y el dato se calculan
en un ciclo y se presentan en el siguiente. No es un adorno: el ADR 0001 reserva media década de
reloj para el acceso **suponiendo que la dirección llega lista**, y mientras se calculaba
combinacionalmente esa media década tenía que cubrir además el decodificador, el banco de registros
y el sumador del desplazamiento — 35 ns, y el diseño se quedaba en 15 MHz. Si escribes una
instrucción nueva que toque la SRAM, usa `next_dm_addr`/`next_dm_re`/`next_dm_we`/`next_dm_wdata`
en el ciclo ANTERIOR al acceso, nunca `dm_*` directamente.

**Las excepciones son `IN`, `OUT`, `SBI`, `CBI`, `SBIC`, `SBIS`** —de uno o dos ciclos, sin ciclo
anterior donde registrar— **y `LDS`/`STS`**, cuya dirección es la segunda palabra y no llega hasta
el ciclo 1. Ésas siguen siendo combinacionales y no se pueden arreglar sin romper L3.

**EL PRESCALER ES UN MÓDULO APARTE, Y NO ES UN CAPRICHO.** En el AVR no hay un prescaler por
temporizador: hay UN contador de 10 bits libre, compartido por Timer0 y Timer1, del que cada uno
elige una toma con sus bits CS. Arrancar un temporizador NO lo pone a cero; lo único que lo resetea
es `GTCCR.PSRSYNC`. Por eso vive en `axioma_prescaler.v` y por eso `GTCCR` es suyo. En la fase 3 el
Timer1 se engancha al mismo módulo sin tocar nada.

**QUIÉN ES EL ORÁCULO DE QUÉ, EN LAS INTERRUPCIONES.** simavr no cuenta ciclo a ciclo: interpola
`TCNT0` desde `avr->cycle` y ancla su base en el ciclo en que se escribe `TCCR0B`. Compararlo en
paralelo sería comparar dos relojes. El reparto que funciona, y que hay que mantener con cada
periférico que genere interrupciones:

- **cuándo** salta → lo decide el RTL, y lo verifica su banco propio contra la hoja de datos;
- **qué hace el núcleo** al saltar → lo verifica simavr: el arnés le levanta ESE MISMO vector con
  `avr_raise_interrupt` y le deja ejecutar su propia secuencia de entrada, y después se comparan PC,
  pila, SP y SREG.

Consecuencia: `TCNT0`, `TIFR0` y `GTCCR` están FUERA de la tabla `COMPARABLE[]`, y los programas de
prueba no pueden leerlos. Sí entran `TCCR0A`, `TCCR0B`, `OCR0A`, `OCR0B` y `TIMSK0`.

**EL RETARDO DE `SEI` LO COMPRUEBA EL ARNÉS, no simavr.** Como es el RTL quien decide cuándo salta,
simavr no le puede desmentir. `diff.cpp` lleva la cuenta: si el RTL entra en una ISR en el paso
inmediatamente posterior a un `SEI`, lo dice y para. `irq_timer0.S` deja una bandera YA pendiente
antes del `SEI` justo para que la regla se ejerza de verdad.

**`PSRSYNC` y `PSRASY` se autolimpian salvo con `TSM` puesto**, así que `GTCCR` se lee como cero
casi siempre. Es lo que dice la hoja de datos —«normally cleared immediately by hardware»— y evita
un ciclo de vida observable que el chip no tiene.

---

## 6. Trampas ya pagadas — no vuelvas a caer

- **`avr_run_one()` de simavr ejecuta UNA INSTRUCCIÓN completa** y devuelve el PC nuevo.
  **El llamante tiene que asignarlo:** `avr->pc = avr_run_one(avr);`. Si no, el PC parece no
  moverse aunque la instrucción sí se ejecute.
- **`ICALL` e `IJMP` saltan a la dirección de PALABRA.** En ensamblador van con
  `pm_lo8()`/`pm_hi8()`, **no** `lo8()`/`hi8()`. El arnés ya lo diagnostica.
- **`LDI` solo admite R16..R31.**
- **`make mutation` MODIFICA EL RTL EN SITIO.** Tiene cerrojo (`build/.mutation.lock`) y
  manejadores de señal, pero **no ejecutes nada en paralelo con él**: una regresión simultánea da
  fallos falsos. Ya pasó.
- **Y dejaba los BINARIOS del último mutante en `build/`.** Restauraba los ficheros, no los
  artefactos. Ejecutar `./build/vdiff/diff` a mano justo después corría un mutante: me costó un
  rato de depuración de un `MOVW` que estaba bien. Desde el 9-sep-2026 la mutación reconstruye y
  exige verde al terminar, pero si alguna vez ves algo imposible, empieza por `make sim-diff`.
- **El PC del RTL es de 14 bits y da la vuelta en `0x4000`**; el de simavr no. Es correcto para un
  328P. Si un programa se sale del rango, el arnés lo dice: casi siempre es fallo del test.
- **En la fase 1 el espacio de I/O del RTL es memoria plana** y simavr sí modela periféricos.
  Los programas de prueba deben evitarlos. SPL, SPH y SREG sí funcionan.
- **Las direcciones de I/O seguras son los tres GPIOR**, que son almacenamiento puro en ambos
  lados: `GPIOR0` dato `0x3E` / I/O `0x1E`, `GPIOR1` `0x4A`/`0x2A`, `GPIOR2` `0x4B`/`0x2B`.
  GPIOR0 cae dentro de `0x00–0x1F`, así que es el único al que llegan `SBI`/`CBI`/`SBIC`/`SBIS`.
- **simavr inicializa la flash a `0xFF`** (flash borrada de verdad) y `axioma_progmem` a `0x0000`
  (NOP). Un programa que lea flash **sin programar** hace divergir el contraste sin que haya nada
  roto. Ya pasó con `LPM`: es fallo del test.
- **`SLEEP` pone a simavr en `cpu_Sleeping`** y el arnés termina ahí, porque su bucle sólo avanza
  mientras simavr corra. Tiene que ser la ÚLTIMA instrucción de su programa; si va en medio, todo
  lo que venga detrás queda sin ejecutar en silencio. `BREAK`, en cambio, es NOP sin gdb.
- **Los ciclos de simavr NO son oráculo.** El comentario de `avr_run_one` en `sim_core.c` avisa de
  que su cuenta «might not be entirely accurate». El oráculo es la tabla del manual; simavr es
  contraste, y sus discrepancias se informan aparte para adjudicarlas a mano.
- **El ciclo de calentamiento tras el reset se le imputaría a la primera instrucción.** El arnés no
  lo ignora: exige que cueste exactamente uno.
- **LOS DOS FALLOS DE LA ENTRADA A ISR**, que estuvieron escritos y sin ejercer desde la fase 1 y
  aparecieron en la primera ejecución de `irq_timer0.S`. Los dos están en el catálogo de mutación:
  - el vector se calculaba como `{9'b0, irq_vector, 2'b00}`, es decir, **por cuatro**. Cada vector
    ocupa DOS palabras —el salto es un `JMP`—, así que le toca `vector × 2`. simavr hace la misma
    cuenta en bytes: `vector * vector_size` con `vector_size = 4`.
  - la máquina de estados se sostenía con `irq_take`, que incluye `cyc == 2'd0`… y esa condición
    deja de cumplirse en cuanto el ciclo 0 limpia el bit `I`. Los ciclos 1 a 3 se caían al `case`
    de instrucciones. Ahora hay un registro `in_irq` que la sostiene hasta el final.
- **AL LEER UNA SEÑAL DE OBSERVACIÓN EN EL ARNÉS, CAPTÚRALA ANTES DEL FLANCO.** `rtl_step()` mira
  `dbg_retire` antes de `tick()` y devuelve DESPUÉS: cualquier otra señal leída al volver ya es del
  ciclo siguiente. Con `dbg_irq_entry` costó una depuración: el arnés no veía ninguna entrada a ISR
  y las comparaba contra instrucciones. Es el mismo error de fase que hacía ejecutar cada
  instrucción dos veces.
- **LOS ANCHOS DE UNA CONCATENACIÓN SON EL MAPA DE VECTORES.** `irq_src` es
  `{9'b0, ovf, compb, compa, 14'b0}` y suma 26. Con un bit de más en el campo de abajo,
  `TIMER0_COMPA` se convierte en `TIMER1_OVF` y el núcleo salta a otro sitio. El lint avisó del
  ancho, y el arreglo evidente —tocar el campo de arriba— era el equivocado.
- **EL RTL NO PUEDE DEPENDER DE UN ARTEFACTO DE COMPILACIÓN.** El top de la placa tenía
  `INIT_HEX = "build/fw/blink.mem"` por defecto, y `axioma_progmem` hace `$readmemh` con él. En mi
  árbol existía porque había construido el bitstream; en una copia recién clonada —la CI— no, y
  yosys aborta. Tres commits en rojo por eso. `INIT_HEX` va **vacío** por defecto y el programa se
  lo pasa quien hace el bitstream, con `chparam`.
- **AL AÑADIR UN BANCO, AÑÁDELO TAMBIÉN A `.github/workflows/ci.yml`.** Ya pasó dos veces: primero
  con `sim-timer0` y `sim-irq`, luego con `sim-usart`. El Makefile y la CI no se actualizan solos, y
  un banco que no corre en el servidor no protege nada.
- **EL DATO DE UN PERIFÉRICO HAY QUE REGISTRARLO EN EL BUS.** Es combinacional desde `io_addr`:
  vale mientras la dirección esté presente y desaparece cuando el secuenciador la suelta. El de la
  SRAM va registrado en flanco de bajada (ADR 0001) y sobrevive al ciclo siguiente. Por eso toda
  instrucción que consuma la lectura UN CICLO DESPUÉS —`LD` y `LDD` lo hacen— leía 0x00 de
  cualquier periférico, desde la fase 1. No se vio porque con la SRAM no se nota y porque `IN` y
  `LDS` consumen dentro del mismo ciclo: hizo falta leer de vuelta un registro de la I/O
  **extendida**, que sólo se alcanza con `LD`/`LDD`/`LDS`. Arreglado en `axioma_dbus`, con mutante.
- **simavr ARRANCA CON `TXEN` PUESTO**, y a propósito: su `avr_uart_reset` lleva el comentario
  «DEBUG allow printf without fiddling with enabling the uart». Por eso `UCSR0B` está fuera del
  barrido del espacio de datos.
- **CON ONDAS PERFECTAS, EL VOTO POR MAYORÍA PARECE DECORATIVO.** El mutante que lo quita sobrevivía
  a todo el banco de la USART. Hay que INYECTAR RUIDO: un pulso de una muestra barrido por todas
  las posiciones del bit. Espera lo mismo de cualquier receptor futuro —SPI, TWI, el ADC—.
- **EL `python3` DE LA OSS CAD SUITE ENVENENA A SUS HIJOS.** `py3bin/python3` se pone `PYTHONHOME`
  a sí mismo EN EL ENTORNO DEL PROCESO, y lo hereda todo lo que lance. El Makefile usa el python del
  venv —el que tiene numpy—, y arrancado con ese `PYTHONHOME` muere con
  «No module named 'encodings'». No se nota con `make mutation`, sí con
  `python3 sim/mutation.py`: la mutación acababa con «tras restaurar, sim-decode NO pasa» sin haber
  nada roto. `sim/mutation.py` ya limpia la variable antes de lanzar `make`.
- **simavr y el Timer0: CINCO diferencias**, todas adjudicadas a favor de la hoja de datos y
  anotadas en `docs/01-arquitectura.md` §8bis. Reinicia la fase del prescaler al escribir `TCCR0B`;
  no modela `GTCCR` en absoluto; convierte en 0 una escritura a `TCNT0` de un valor ≥ TOP; devuelve
  0 al leer `TCNT0` con el temporizador parado; y no cuenta ciclo a ciclo, sino que interpola.
- **El arnés llama a `avr_service_interrupts()` tras CADA instrucción**, aunque no haya nada
  pendiente: es lo que lleva la cuenta del retardo de `SEI` dentro de simavr. Sin eso, la primera
  interrupción de verdad se queda sin atender y el arnés lo reporta como «simavr NO ATENDIÓ EL
  VECTOR».

---

## 7. Cuestiones abiertas

**La toma de clk/1 bajo `TSM`.** La figura «Prescaler for Timer/Counter0 and Timer/Counter1» saca
`clk_I/O` directamente, sin pasar por el contador de 10 bits, así que `TSM` no debería detener a un
temporizador con `CS=001`. La hoja de datos no lo dice con palabras. Se implementa la lectura
literal de la figura: `tick_1` no lo afecta ni `PSRSYNC` ni `TSM`. **Pendiente de confirmar.**

**`SPM Z+` (`0x95F8`).** No se ha podido confirmar si el 328P lo implementa: binutils lo decodifica
en todas las arquitecturas AVR, incluida avr2, así que no es *device-aware*; `boot.h` de avr-libc
no lo usa. Se acepta como superset porque solo puede sumar compatibilidad. **Pendiente de
confirmar contra la hoja de datos.**

---

## 8. Cómo trabaja este usuario

- **Los `.md` no se comitean**, salvo `README.md`. Actualízalos igualmente.
  (Excepción hecha el 9-sep-2026: `LICENSE-EXCEPTIONS.md`, porque se añadió una foto de la ULX3S y
  la regla 1 de ese inventario exige registrar todo componente de terceros.)
- **Sin trailers de coautoría.** El historial se reescribió para eliminarlos.
- Mensajes de commit en **castellano**, voz llana de ingeniería, sin cabeceras decorativas.
- Pide **verificación antes de avanzar**. Cuando pregunta «¿todo va bien?» quiere un estado honesto
  por módulo. Cuando pregunta «¿está al 100 %?» quiere que **busques más agujeros**, no un sí.
- El clasificador de permisos **bloquea `git push --force`** y las limpiezas destructivas de git.
  No lo rodees: dale el comando para que lo ejecute con `!`.
- El remoto usa **SSH**. Con HTTPS, un PAT sin scope `workflow` no puede tocar `.github/workflows/`.

---

## 9. Arrancar

```bash
cd ~/Documents/AxiomaCore-328
source env.sh
make check-tools
make lint regmap-check lpf sim-alu sim-sreg sim-regfile sim-mem sim-dbus sim-gpio \
     sim-timer0 sim-irq sim-simavr sim-decode sim-diff sim-random
```

Las quince deben pasar. Instalación desde cero: `INSTALL.md`.

Para depurar el núcleo: `./build/vdiff/diff build/diff/<test>.bin` señala la instrucción exacta
donde diverge, con el estado de ambos lados.

---

## 10. Respaldos

- `~/eda/axioma-backup-pre-restructure-20260908-1221.bundle` — historial original
- `~/eda/axioma-pre-trailer-strip-20260908-1757.bundle` — antes de quitar los trailers
- `~/eda/axioma-wip-*.patch` — trabajo sin comitear

Se restauran con `git clone <bundle>`.
