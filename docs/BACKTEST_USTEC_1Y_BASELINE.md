# BACKTEST USTEC 1Y — Baseline LADDER v8 (IC Markets EU)

Fecha: 2026-10-03. EA: `LADDER_v8.mq5` v8.04 (compila OK, `LADDER_v8.ex5` 66 KB).
Cuenta real verificada: ICMarketsEU-MT5-5, EUR, apalancamiento 1:30, hedging (margin_mode=2).

## 1. Specs USTEC verificadas en vivo (symbol_info)

| Spec | Valor | Implicación EA |
|---|---|---|
| TickSize / Point / Digits | 0.01 / 0.01 / 2 | `InpUnit=0.1` = 10× TickSize exacto → **OnInit OK** |
| VolumeMin / Step / Max | 0.1 / 0.1 / 250 | Lotes 0.1/0.2/0.3/0.4 **exactos, viables**; `LotFor()` no recorta |
| StopsLevel / Freeze | 0 / 0 | SL 8.0 y cualquier TP **sin distancia mínima** → OK |
| Contract size | 1.0 | — |
| Spread 01-10-2026 09:30–11:30 NY (28406 ticks) | **1.00 precio, estable (min=max=1.00)** = 10 ticks EA | `MaxSpread=30` (3.0) → **3× holgura, viable** |
| EPL medido (`OrderCalcProfit`, ask 30787.2) | **0.09 EUR por 1.0 lote × 0.1 precio** | base de todos los cálculos |
| Pérdida SL 8.0 precio, 0.1 lote | **≈ −0.71 EUR** (+spread ≈ −0.09) | escalera completa worst ≈ 1.0×0.09×(80+30+10) ≈ **10 EUR ≪ topes 100** |
| Margen 0.4 lote @30787 | ≈ **547 EUR** | con `MaxMarginUsePct=50` y depósito < ~1100 EUR el nivel 4 se bloquea |

Zona horaria: servidor = NY+7h en octubre (EDT+EEST). `InpServerMinusNYHours=7` correcto en ventana del backtest;
ojo divergencia DST fin-oct y marzo (offset pasa a 6/8 unas semanas) — el EA usa offset fijo en tester.

## 2. BLOQUEO CRÍTICO: baseline v8 sin cambios NO opera

`OpenLevel` calcula `need = InpTargetEUR − g_cyclePL`, `tpPts = need/(lot×epl)`:

- Nivel 1: `tpPts = 5.00/(0.1×0.09) ≈ 555 ticks EA (55.5 precio)` **> `InpMaxTPPts=300`** → `return -2`, `TP_NECESARIO_EXCESIVO`, `EndCycle + g_stopped`.
- Resultado esperado sin cambios: **0 trades, journal lleno de `TP necesario … > maximo`**. OnInit pasa (solo avisa), el bloqueo es en apertura.

Opciones (elegida A):
- **A. `InpTargetEUR=2.0`**: TP1 ≈ 222 ticks (22.2 precio) < 300 OK; niveles 2–4 ≈ 150–260 ticks, todos < 300. SL 8.0 vs TP 22.2.
- B. `InpMaxTPPts=600` con Target 5.0: TP1 55.5 precio = 7× SL, RR inasumible. Descartada.

`.set` entregado aplica opción A + `InpMaxMarginUsePct=0` (off, evita filtro de margen con depósitos pequeños).

## 3. Settings exactos backtest 1 año

| Parámetro | Valor |
|---|---|
| Rango | **2025-10-01 → 2026-10-01** (año completo, incluye 2 transiciones DST) |
| Símbolo / TF / Modo | USTEC / M1 / **Every tick based on real ticks (Model=4)** |
| Depósito / Moneda / Leverage | **10000 / EUR / 1:30** |
| Cuenta | Hedging (retiene `InpBlockForeignPosition=true`) |
| Spread | **Real (ticks reales)**; filtro EA `MaxSpread=30` (≈3× spread medio 10) |
| Inputs EA | `.set` baseline (Target 2.0, resto stock) |
| Ejecución | `terminal64.exe` + `LADDER_v8_USTEC_baseline_tester.ini`, o manual en Strategy Tester |

## 4. Estado del backtest

**NO ejecutado**: el terminal en uso es la sesión live del usuario; lanzar el Tester headless contra el mismo
`data_path` la secuestraría. Queda el `.ini` listo para ejecución desatendida o manual (5–15 min aprox. en real ticks).
Para lanzar: cerrar/confirmar con el usuario, compilar ya hecho, correr ini, recoger `Report` + journal
(`TP_NECESARIO_EXCESIVO` debe ser 0; si aparece, revisar).

## 5. Checklist datos

- [x] Historial M1 disponible desde ≥2023-09 (verificado vía `copy_rates`, 500k barras desde 2024-10-01)
- [ ] Descargar ticks reales del rango en Tester (automático al correr Model=4; verificar pestaña Journal sin gaps)
- [ ] Festivos: USTEC cierra Acción de Gracias 27-11, Navidad 25-12, 01-01 — el EA no filtra festivos; cruzar días sin operar con calendario
- [ ] Tras correr: nº trades, días SIN OPERAR (sesgo=0), neto, max DD, Profit Factor → tabla aquí

## Archivos

- `Shared\Transfers\LADDER_v8_USTEC_baseline.set` — inputs viables (Target 2.0, margen off)
- `Shared\Transfers\LADDER_v8_USTEC_baseline_tester.ini` — config Tester 1Y desatendida
- `Experts\LADDER_v8.mq5` + `.ex5` — fuente del repo compilada en el terminal
