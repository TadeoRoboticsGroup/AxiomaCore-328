# Mapa de registros

> **Fichero generado.** No editar a mano.
> Generador: `tools/gen_regmap.py` · Fuente: preprocesador de avr-gcc con avr-libc (BSD-3-Clause).
> Regenerar con `make regmap`; la CI falla si este fichero diverge de la fuente.

Direcciones del **espacio de datos**. Para `IN`/`OUT`, la dirección de I/O es
`dirección de dato − 0x20`. `CBI`/`SBI`/`SBIC`/`SBIS` sólo alcanzan I/O `0x00–0x1F`.

## Registros

| Dato | I/O | Registro | Bits |
|------|-----|----------|------|
| `0x23` | `0x03` | **PINB** | `PINB7`=7, `PINB6`=6, `PINB5`=5, `PINB4`=4, `PINB3`=3, `PINB2`=2, `PINB1`=1, `PINB0`=0 |
| `0x24` | `0x04` | **DDRB** | `DDB7`=7, `DDB6`=6, `DDB5`=5, `DDB4`=4, `DDB3`=3, `DDB2`=2, `DDB1`=1, `DDB0`=0 |
| `0x25` | `0x05` | **PORTB** | `PORTB7`=7, `PORTB6`=6, `PORTB5`=5, `PORTB4`=4, `PORTB3`=3, `PORTB2`=2, `PORTB1`=1, `PORTB0`=0 |
| `0x26` | `0x06` | **PINC** | `PINC6`=6, `PINC5`=5, `PINC4`=4, `PINC3`=3, `PINC2`=2, `PINC1`=1, `PINC0`=0 |
| `0x27` | `0x07` | **DDRC** | `DDC6`=6, `DDC5`=5, `DDC4`=4, `DDC3`=3, `DDC2`=2, `DDC1`=1, `DDC0`=0 |
| `0x28` | `0x08` | **PORTC** | `PORTC6`=6, `PORTC5`=5, `PORTC4`=4, `PORTC3`=3, `PORTC2`=2, `PORTC1`=1, `PORTC0`=0 |
| `0x29` | `0x09` | **PIND** | `PIND7`=7, `PIND6`=6, `PIND5`=5, `PIND4`=4, `PIND3`=3, `PIND2`=2, `PIND1`=1, `PIND0`=0 |
| `0x2A` | `0x0A` | **DDRD** | `DDD7`=7, `DDD6`=6, `DDD5`=5, `DDD4`=4, `DDD3`=3, `DDD2`=2, `DDD1`=1, `DDD0`=0 |
| `0x2B` | `0x0B` | **PORTD** | `PORTD7`=7, `PORTD6`=6, `PORTD5`=5, `PORTD4`=4, `PORTD3`=3, `PORTD2`=2, `PORTD1`=1, `PORTD0`=0 |
| `0x35` | `0x15` | **TIFR0** | `OCF0B`=2, `OCF0A`=1, `TOV0`=0 |
| `0x36` | `0x16` | **TIFR1** | `ICF1`=5, `OCF1B`=2, `OCF1A`=1, `TOV1`=0 |
| `0x37` | `0x17` | **TIFR2** | `OCF2B`=2, `OCF2A`=1, `TOV2`=0 |
| `0x3B` | `0x1B` | **PCIFR** | `PCIF2`=2, `PCIF1`=1, `PCIF0`=0 |
| `0x3C` | `0x1C` | **EIFR** | `INTF1`=1, `INTF0`=0 |
| `0x3D` | `0x1D` | **EIMSK** | `INT1`=1, `INT0`=0 |
| `0x3E` | `0x1E` | **GPIOR0** | `GPIOR07`=7, `GPIOR06`=6, `GPIOR05`=5, `GPIOR04`=4, `GPIOR03`=3, `GPIOR02`=2, `GPIOR01`=1, `GPIOR00`=0 |
| `0x3F` | `0x1F` | **EECR** | `EEPM1`=5, `EEPM0`=4, `EERIE`=3, `EEMPE`=2, `EEPE`=1, `EERE`=0 |
| `0x40` | `0x20` | **EEDR** | `EEDR7`=7, `EEDR6`=6, `EEDR5`=5, `EEDR4`=4, `EEDR3`=3, `EEDR2`=2, `EEDR1`=1, `EEDR0`=0 |
| `0x41` | `0x21` | **EEARL** | `EEAR7`=7, `EEAR6`=6, `EEAR5`=5, `EEAR4`=4, `EEAR3`=3, `EEAR2`=2, `EEAR1`=1, `EEAR0`=0 |
| `0x42` | `0x22` | **EEARH** | `EEAR9`=1, `EEAR8`=0 |
| `0x43` | `0x23` | **GTCCR** | `TSM`=7, `PSRASY`=1, `PSRSYNC`=0 |
| `0x44` | `0x24` | **TCCR0A** | `COM0A1`=7, `COM0A0`=6, `COM0B1`=5, `COM0B0`=4, `WGM01`=1, `WGM00`=0 |
| `0x45` | `0x25` | **TCCR0B** | `FOC0A`=7, `FOC0B`=6, `WGM02`=3, `CS02`=2, `CS01`=1, `CS00`=0 |
| `0x46` | `0x26` | **TCNT0** | `TCNT0_7`=7, `TCNT0_6`=6, `TCNT0_5`=5, `TCNT0_4`=4, `TCNT0_3`=3, `TCNT0_2`=2, `TCNT0_1`=1, `TCNT0_0`=0 |
| `0x47` | `0x27` | **OCR0A** | `OCR0A_7`=7, `OCR0A_6`=6, `OCR0A_5`=5, `OCR0A_4`=4, `OCR0A_3`=3, `OCR0A_2`=2, `OCR0A_1`=1, `OCR0A_0`=0 |
| `0x48` | `0x28` | **OCR0B** | `OCR0B_7`=7, `OCR0B_6`=6, `OCR0B_5`=5, `OCR0B_4`=4, `OCR0B_3`=3, `OCR0B_2`=2, `OCR0B_1`=1, `OCR0B_0`=0 |
| `0x4A` | `0x2A` | **GPIOR1** | `GPIOR17`=7, `GPIOR16`=6, `GPIOR15`=5, `GPIOR14`=4, `GPIOR13`=3, `GPIOR12`=2, `GPIOR11`=1, `GPIOR10`=0 |
| `0x4B` | `0x2B` | **GPIOR2** | `GPIOR27`=7, `GPIOR26`=6, `GPIOR25`=5, `GPIOR24`=4, `GPIOR23`=3, `GPIOR22`=2, `GPIOR21`=1, `GPIOR20`=0 |
| `0x4C` | `0x2C` | **SPCR** | `SPIE`=7, `SPE`=6, `DORD`=5, `MSTR`=4, `CPOL`=3, `CPHA`=2, `SPR1`=1, `SPR0`=0 |
| `0x4D` | `0x2D` | **SPSR** | `SPIF`=7, `WCOL`=6, `SPI2X`=0 |
| `0x4E` | `0x2E` | **SPDR** | `SPDR7`=7, `SPDR6`=6, `SPDR5`=5, `SPDR4`=4, `SPDR3`=3, `SPDR2`=2, `SPDR1`=1, `SPDR0`=0 |
| `0x50` | `0x30` | **ACSR** | `ACD`=7, `ACBG`=6, `ACO`=5, `ACI`=4, `ACIE`=3, `ACIC`=2, `ACIS1`=1, `ACIS0`=0 |
| `0x53` | `0x33` | **SMCR** | `SM2`=3, `SM1`=2, `SM0`=1, `SE`=0 |
| `0x54` | `0x34` | **MCUSR** | `WDRF`=3, `BORF`=2, `EXTRF`=1, `PORF`=0 |
| `0x55` | `0x35` | **MCUCR** | `BODS`=6, `BODSE`=5, `PUD`=4, `IVSEL`=1, `IVCE`=0 |
| `0x57` | `0x37` | **SPMCSR** | `SPMIE`=7, `RWWSB`=6, `SIGRD`=5, `RWWSRE`=4, `BLBSET`=3, `PGWRT`=2, `PGERS`=1, `SELFPRGEN`=0, `SPMEN`=0 |
| `0x5D` | `0x3D` | **SPL** | — |
| `0x5E` | `0x3E` | **SPH** | — |
| `0x5F` | `0x3F` | **SREG** | `SREG_I`=7, `SREG_T`=6, `SREG_H`=5, `SREG_S`=4, `SREG_V`=3, `SREG_N`=2, `SREG_Z`=1, `SREG_C`=0 |
| `0x60` | — | **WDTCSR** | `WDIF`=7, `WDIE`=6, `WDP3`=5, `WDCE`=4, `WDE`=3, `WDP2`=2, `WDP1`=1, `WDP0`=0 |
| `0x61` | — | **CLKPR** | `CLKPCE`=7, `CLKPS3`=3, `CLKPS2`=2, `CLKPS1`=1, `CLKPS0`=0 |
| `0x64` | — | **PRR** | `PRTWI`=7, `PRTIM2`=6, `PRTIM0`=5, `PRTIM1`=3, `PRSPI`=2, `PRUSART0`=1, `PRADC`=0 |
| `0x66` | — | **OSCCAL** | `CAL7`=7, `CAL6`=6, `CAL5`=5, `CAL4`=4, `CAL3`=3, `CAL2`=2, `CAL1`=1, `CAL0`=0 |
| `0x68` | — | **PCICR** | `PCIE2`=2, `PCIE1`=1, `PCIE0`=0 |
| `0x69` | — | **EICRA** | `ISC11`=3, `ISC10`=2, `ISC01`=1, `ISC00`=0 |
| `0x6B` | — | **PCMSK0** | `PCINT7`=7, `PCINT6`=6, `PCINT5`=5, `PCINT4`=4, `PCINT3`=3, `PCINT2`=2, `PCINT1`=1, `PCINT0`=0 |
| `0x6C` | — | **PCMSK1** | `PCINT14`=6, `PCINT13`=5, `PCINT12`=4, `PCINT11`=3, `PCINT10`=2, `PCINT9`=1, `PCINT8`=0 |
| `0x6D` | — | **PCMSK2** | `PCINT23`=7, `PCINT22`=6, `PCINT21`=5, `PCINT20`=4, `PCINT19`=3, `PCINT18`=2, `PCINT17`=1, `PCINT16`=0 |
| `0x6E` | — | **TIMSK0** | `OCIE0B`=2, `OCIE0A`=1, `TOIE0`=0 |
| `0x6F` | — | **TIMSK1** | `ICIE1`=5, `OCIE1B`=2, `OCIE1A`=1, `TOIE1`=0 |
| `0x70` | — | **TIMSK2** | `OCIE2B`=2, `OCIE2A`=1, `TOIE2`=0 |
| `0x78` | — | **ADCL** | `ADCL7`=7, `ADCL6`=6, `ADCL5`=5, `ADCL4`=4, `ADCL3`=3, `ADCL2`=2, `ADCL1`=1, `ADCL0`=0 |
| `0x79` | — | **ADCH** | `ADCH7`=7, `ADCH6`=6, `ADCH5`=5, `ADCH4`=4, `ADCH3`=3, `ADCH2`=2, `ADCH1`=1, `ADCH0`=0 |
| `0x7A` | — | **ADCSRA** | `ADEN`=7, `ADSC`=6, `ADATE`=5, `ADIF`=4, `ADIE`=3, `ADPS2`=2, `ADPS1`=1, `ADPS0`=0 |
| `0x7B` | — | **ADCSRB** | `ACME`=6, `ADTS2`=2, `ADTS1`=1, `ADTS0`=0 |
| `0x7C` | — | **ADMUX** | `REFS1`=7, `REFS0`=6, `ADLAR`=5, `MUX3`=3, `MUX2`=2, `MUX1`=1, `MUX0`=0 |
| `0x7E` | — | **DIDR0** | `ADC5D`=5, `ADC4D`=4, `ADC3D`=3, `ADC2D`=2, `ADC1D`=1, `ADC0D`=0 |
| `0x7F` | — | **DIDR1** | `AIN1D`=1, `AIN0D`=0 |
| `0x80` | — | **TCCR1A** | `COM1A1`=7, `COM1A0`=6, `COM1B1`=5, `COM1B0`=4, `WGM11`=1, `WGM10`=0 |
| `0x81` | — | **TCCR1B** | `ICNC1`=7, `ICES1`=6, `WGM13`=4, `WGM12`=3, `CS12`=2, `CS11`=1, `CS10`=0 |
| `0x82` | — | **TCCR1C** | `FOC1A`=7, `FOC1B`=6 |
| `0x84` | — | **TCNT1L** | `TCNT1L7`=7, `TCNT1L6`=6, `TCNT1L5`=5, `TCNT1L4`=4, `TCNT1L3`=3, `TCNT1L2`=2, `TCNT1L1`=1, `TCNT1L0`=0 |
| `0x85` | — | **TCNT1H** | `TCNT1H7`=7, `TCNT1H6`=6, `TCNT1H5`=5, `TCNT1H4`=4, `TCNT1H3`=3, `TCNT1H2`=2, `TCNT1H1`=1, `TCNT1H0`=0 |
| `0x86` | — | **ICR1L** | `ICR1L7`=7, `ICR1L6`=6, `ICR1L5`=5, `ICR1L4`=4, `ICR1L3`=3, `ICR1L2`=2, `ICR1L1`=1, `ICR1L0`=0 |
| `0x87` | — | **ICR1H** | `ICR1H7`=7, `ICR1H6`=6, `ICR1H5`=5, `ICR1H4`=4, `ICR1H3`=3, `ICR1H2`=2, `ICR1H1`=1, `ICR1H0`=0 |
| `0x88` | — | **OCR1AL** | `OCR1AL7`=7, `OCR1AL6`=6, `OCR1AL5`=5, `OCR1AL4`=4, `OCR1AL3`=3, `OCR1AL2`=2, `OCR1AL1`=1, `OCR1AL0`=0 |
| `0x89` | — | **OCR1AH** | `OCR1AH7`=7, `OCR1AH6`=6, `OCR1AH5`=5, `OCR1AH4`=4, `OCR1AH3`=3, `OCR1AH2`=2, `OCR1AH1`=1, `OCR1AH0`=0 |
| `0x8A` | — | **OCR1BL** | `OCR1BL7`=7, `OCR1BL6`=6, `OCR1BL5`=5, `OCR1BL4`=4, `OCR1BL3`=3, `OCR1BL2`=2, `OCR1BL1`=1, `OCR1BL0`=0 |
| `0x8B` | — | **OCR1BH** | `OCR1BH7`=7, `OCR1BH6`=6, `OCR1BH5`=5, `OCR1BH4`=4, `OCR1BH3`=3, `OCR1BH2`=2, `OCR1BH1`=1, `OCR1BH0`=0 |
| `0xB0` | — | **TCCR2A** | `COM2A1`=7, `COM2A0`=6, `COM2B1`=5, `COM2B0`=4, `WGM21`=1, `WGM20`=0 |
| `0xB1` | — | **TCCR2B** | `FOC2A`=7, `FOC2B`=6, `WGM22`=3, `CS22`=2, `CS21`=1, `CS20`=0 |
| `0xB2` | — | **TCNT2** | `TCNT2_7`=7, `TCNT2_6`=6, `TCNT2_5`=5, `TCNT2_4`=4, `TCNT2_3`=3, `TCNT2_2`=2, `TCNT2_1`=1, `TCNT2_0`=0 |
| `0xB3` | — | **OCR2A** | `OCR2_7`=7, `OCR2_6`=6, `OCR2_5`=5, `OCR2_4`=4, `OCR2_3`=3, `OCR2_2`=2, `OCR2_1`=1, `OCR2_0`=0 |
| `0xB4` | — | **OCR2B** | `OCR2_7`=7, `OCR2_6`=6, `OCR2_5`=5, `OCR2_4`=4, `OCR2_3`=3, `OCR2_2`=2, `OCR2_1`=1, `OCR2_0`=0 |
| `0xB6` | — | **ASSR** | `EXCLK`=6, `AS2`=5, `TCN2UB`=4, `OCR2AUB`=3, `OCR2BUB`=2, `TCR2AUB`=1, `TCR2BUB`=0 |
| `0xB8` | — | **TWBR** | `TWBR7`=7, `TWBR6`=6, `TWBR5`=5, `TWBR4`=4, `TWBR3`=3, `TWBR2`=2, `TWBR1`=1, `TWBR0`=0 |
| `0xB9` | — | **TWSR** | `TWS7`=7, `TWS6`=6, `TWS5`=5, `TWS4`=4, `TWS3`=3, `TWPS1`=1, `TWPS0`=0 |
| `0xBA` | — | **TWAR** | `TWA6`=7, `TWA5`=6, `TWA4`=5, `TWA3`=4, `TWA2`=3, `TWA1`=2, `TWA0`=1, `TWGCE`=0 |
| `0xBB` | — | **TWDR** | `TWD7`=7, `TWD6`=6, `TWD5`=5, `TWD4`=4, `TWD3`=3, `TWD2`=2, `TWD1`=1, `TWD0`=0 |
| `0xBC` | — | **TWCR** | `TWINT`=7, `TWEA`=6, `TWSTA`=5, `TWSTO`=4, `TWWC`=3, `TWEN`=2, `TWIE`=0 |
| `0xBD` | — | **TWAMR** | `TWAM6`=6, `TWAM5`=5, `TWAM4`=4, `TWAM3`=3, `TWAM2`=2, `TWAM1`=1, `TWAM0`=0 |
| `0xC0` | — | **UCSR0A** | `RXC0`=7, `TXC0`=6, `UDRE0`=5, `FE0`=4, `DOR0`=3, `UPE0`=2, `U2X0`=1, `MPCM0`=0 |
| `0xC1` | — | **UCSR0B** | `RXCIE0`=7, `TXCIE0`=6, `UDRIE0`=5, `RXEN0`=4, `TXEN0`=3, `UCSZ02`=2, `RXB80`=1, `TXB80`=0 |
| `0xC2` | — | **UCSR0C** | `UMSEL01`=7, `UMSEL00`=6, `UPM01`=5, `UPM00`=4, `USBS0`=3, `UCSZ01`=2, `UDORD0`=2, `UCSZ00`=1, `UCPHA0`=1, `UCPOL0`=0 |
| `0xC4` | — | **UBRR0L** | `UBRR0_7`=7, `UBRR0_6`=6, `UBRR0_5`=5, `UBRR0_4`=4, `UBRR0_3`=3, `UBRR0_2`=2, `UBRR0_1`=1, `UBRR0_0`=0 |
| `0xC5` | — | **UBRR0H** | `UBRR0_11`=3, `UBRR0_10`=2, `UBRR0_9`=1, `UBRR0_8`=0 |
| `0xC6` | — | **UDR0** | `UDR0_7`=7, `UDR0_6`=6, `UDR0_5`=5, `UDR0_4`=4, `UDR0_3`=3, `UDR0_2`=2, `UDR0_1`=1, `UDR0_0`=0 |

## Vectores de interrupción

25 vectores. Direcciones **de palabra**; cada vector ocupa 2 palabras
(un `JMP`) porque la Flash es de 32 KB. Prioridad = orden numérico.

| Nº | Palabra | Vector |
|----|---------|--------|
| 0 | `0x0000` | RESET |
| 1 | `0x0002` | INT0 |
| 2 | `0x0004` | INT1 |
| 3 | `0x0006` | PCINT0 |
| 4 | `0x0008` | PCINT1 |
| 5 | `0x000A` | PCINT2 |
| 6 | `0x000C` | WDT |
| 7 | `0x000E` | TIMER2_COMPA |
| 8 | `0x0010` | TIMER2_COMPB |
| 9 | `0x0012` | TIMER2_OVF |
| 10 | `0x0014` | TIMER1_CAPT |
| 11 | `0x0016` | TIMER1_COMPA |
| 12 | `0x0018` | TIMER1_COMPB |
| 13 | `0x001A` | TIMER1_OVF |
| 14 | `0x001C` | TIMER0_COMPA |
| 15 | `0x001E` | TIMER0_COMPB |
| 16 | `0x0020` | TIMER0_OVF |
| 17 | `0x0022` | SPI_STC |
| 18 | `0x0024` | USART_RX |
| 19 | `0x0026` | USART_UDRE |
| 20 | `0x0028` | USART_TX |
| 21 | `0x002A` | ADC |
| 22 | `0x002C` | EE_READY |
| 23 | `0x002E` | ANALOG_COMP |
| 24 | `0x0030` | TWI |
| 25 | `0x0032` | SPM_READY |

---

Los nombres y direcciones proceden de avr-libc, bajo licencia BSD-3-Clause.
Ver [`../LICENSE-EXCEPTIONS.md`](../LICENSE-EXCEPTIONS.md).
