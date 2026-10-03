//+------------------------------------------------------------------+
//| LADDER_v8.06.mq5 (v8.06 tick 0.1: TP=objetivo-P/L ciclo, timeout hist.) |
//| Nasdaq M1. 1) Sesgo fijo a las 09:25 NY: precio vs Londres y     |
//| VWAP -> solo compras o solo ventas ese dia. 2) Entrada EMA9/EMA20|
//| /VWAP (de v7) solo en la direccion del sesgo. 3) Escalera de     |
//| recuperacion con lotes 0.1/0.2/0.3/0.4: el TP de cada nivel se   |
//| calcula para cerrar el ciclo con +objetivo EUR. Perdida maxima   |
//| por escalera y por dia limitada. SIN GARANTIA DE GANAR SIEMPRE.  |
//| v8.05 fixes: offset DST-aware en tester, dia unificado r[1], no parar|
//| por timeout hist. en tester, warmup Bars M1/M15 en OnInit.       |
//| v8.06: InpBiasAllowVWAPOnly=false (default). Si true, sesgo      |
//| se decide SOLO con precio vs VWAP (ignora filtro Londres). Loguea  |
//| que filtro lo decidió. LON_MID sigue disponible via InpLondonRef. |
//| v8.06: InpBiasAllowVWAPOnly - sesgo solo precio vs VWAP         |
//+------------------------------------------------------------------+
#property strict
#property version "8.06"
#property description "Nasdaq: sesgo 09:25 NY (precio vs Londres vs VWAP) + escalera 0.1-0.4 lotes + VWAP-ONLY"

#include <Trade/Trade.mqh>
CTrade Trade;

enum ENUM_LON_REF { LON_MID=0, LON_OPEN=1, LON_RANGE=2 };

input group "Identidad"
input ulong  InpMagic=26100801;
input string InpSymbol="";                  // vacio = simbolo del grafico
input int    InpDeviation=20;

input group "Sesgo (hora NY)"
input int    InpBiasNYMin=565;              // 09:25 NY (minutos desde 00:00)
input int    InpLondonStartNYMin=180;       // inicio Londres: 03:00 NY
input int    InpLondonEndNYMin=540;         // fin Londres: 09:00 NY (rango cerrado)
input ENUM_LON_REF InpLondonRef=LON_RANGE;    // MID: mitad del rango de Londres | OPEN: apertura de Londres | RANGE: por encima del maximo / por debajo del minimo
input bool   InpBiasAllowVWAPOnly=false;     // v8.06: si true, sesgo SOLO precio vs VWAP (ignora Londres), loguea filtro
input int    InpBiasVWAPFromNYMin=-360;     // VWAP del sesgo desde 18:00 NY del dia anterior (negativo = dia anterior)

input group "Senal M1 (de v7)"
input int    InpSigVWAPAnchorNYMin=570;     // VWAP de la senal anclado a las 09:30 NY
input bool   InpUseM15=false;                // true = ademas exige romper max/min de las 2 ultimas M15 cerradas (a 09:25)
input int    InpCooldownBars=2;
input double InpMaxSpread=30.0;             // spread maximo en TICKS EA (1 tick = InpUnit de precio; 30 = 3.0)

input group "Escalera de recuperacion"
input double InpUnit=0.1;                   // 1 tick EA = 0.1 de precio (10 ticks = 1 punto de indice)
input double InpSLPts=80.0;                 // SL fijo en TICKS EA (80 = 8.0 de precio)
input double InpSlipPts=30.0;               // reserva de slippage en TICKS EA (30 = 3.0 de precio)
input double InpTargetEUR=2.0;              // ganancia objetivo por ciclo (v8.05: 2.0 viable en USTEC; 5.0 daba TP1~555>MaxTP300)
input double InpTargetTolEUR=0.05;          // tolerancia para dar el objetivo por cumplido
input double InpCommissionPerLot=0.0;       // comision ida y vuelta por lote (moneda de la cuenta)
input double InpMaxTPPts=300.0;             // TICKS EA; si el TP necesario supera esto, no se abre el nivel (300 = 30.0)
input int    InpLevels=4;                   // max 4
input double InpLot1=0.1;
input double InpLot2=0.2;
input double InpLot3=0.3;
input double InpLot4=0.4;
input double InpLotCap=0.4;                 // tope duro de lote
input double InpMaxLadderLoss=100.0;        // perdida maxima de una escalera (moneda de la cuenta)
input double InpMaxDailyLoss=100.0;         // perdida maxima diaria
input int    InpMaxWinsPerDay=1;            // ciclos ganados por dia antes de parar
input double InpMaxMarginUsePct=50.0;       // % maximo de margen libre por orden (0 = off)
input int    InpHistTimeoutSec=90;          // espera maxima del historial
input bool   InpBlockForeignPosition=true;  // bloquea si existe otra posicion en el simbolo          // espera maxima del historial tras cerrar una operacion; si no aparece, se para el dia

input group "Horario NY"
input bool   InpAutoServerOffset=false;     // true = deduce servidor-NY con TimeGMT (solo real)
input bool   InpTesterOffsetAuto=true;      // v8.05: true = offset DST-aware (6/7h) tambien en tester
input int    InpServerMinusNYHours=7;       // servidor = NY + 7h (IC Markets; 6h en gaps DST US/EU)
input int    InpNYStartMin=570;             // 09:30
input int    InpNYEndMin=690;               // 11:30 fin de ENTRADAS NUEVAS (2 h)
input int    InpHardStopNYMin=960;          // 16:00 cierre de seguridad

string   SYM;
int      hE9=INVALID_HANDLE,hE20=INVALID_HANDLE;
double   TickSize=0,VolMin=0,VolMax=0,VolStep=0;
int      SymDigits=0;
datetime lastbar=0;
int      g_off=7;

int      g_level=0,g_cd=0,g_wins=0,g_bias=0;
bool     g_biasDone=false,g_stopped=false,g_cycleActive=false;
double   g_m15Hi=0,g_m15Lo=0;
string   g_endReason="";
double   g_cyclePL=0,g_dayPL=0;
datetime g_dayKey=0;
datetime g_goneSince=0;
ulong    g_posId=0;
double   g_bPrice=0,g_bLon=0,g_bVWAP=0;
string   g_status="Iniciando";

//==================== tiempo ====================
int DowOf(int y,int m,int d)
  {
   MqlDateTime s;s.year=y;s.mon=m;s.day=d;s.hour=0;s.min=0;s.sec=0;
   datetime t=StructToTime(s);TimeToStruct(t,s);return s.day_of_week;
  }
bool IsUSDST(datetime utc)
  {
   MqlDateTime u;TimeToStruct(utc,u);int y=u.year;
   int secondSunMar=1+((7-DowOf(y,3,1))%7)+7;
   int firstSunNov=1+((7-DowOf(y,11,1))%7);
   MqlDateTime a;a.year=y;a.mon=3;a.day=secondSunMar;a.hour=7;a.min=0;a.sec=0;
   MqlDateTime b;b.year=y;b.mon=11;b.day=firstSunNov;b.hour=6;b.min=0;b.sec=0;
   return utc>=StructToTime(a)&&utc<StructToTime(b);
  }
bool IsEUDST(datetime utc)
  {
   MqlDateTime u;TimeToStruct(utc,u);int y=u.year;
// ultimo domingo de marzo y octubre
   int dMar=31;while(dMar>24&&DowOf(y,3,dMar)!=0)dMar--;
   int dOct=31;while(dOct>24&&DowOf(y,10,dOct)!=0)dOct--;
   MqlDateTime a;a.year=y;a.mon=3;a.day=dMar;a.hour=1;a.min=0;a.sec=0;
   MqlDateTime b;b.year=y;b.mon=10;b.day=dOct;b.hour=1;b.min=0;b.sec=0;
   return utc>=StructToTime(a)&&utc<StructToTime(b);
  }
// Tabla gaps 2024-2026 (US DST on, EU off => 6h, resto 7h). Servidor IC Markets EU.
int TesterOffsetTable(datetime srv)
  {
   if(srv>=D'2024.03.10 00:00'&&srv<D'2024.03.31 00:00')return 6;
   if(srv>=D'2024.10.27 00:00'&&srv<D'2024.11.03 00:00')return 6;
   if(srv>=D'2025.03.09 00:00'&&srv<D'2025.03.30 00:00')return 6;
   if(srv>=D'2025.10.26 00:00'&&srv<D'2025.11.02 00:00')return 6;
   if(srv>=D'2026.03.08 00:00'&&srv<D'2026.03.29 00:00')return 6;
   if(srv>=D'2026.10.25 00:00'&&srv<D'2026.11.01 00:00')return 6;
   MqlDateTime s;TimeToStruct(srv,s);
// fallback generico: usa fecha servidor como proxy UTC (error <1 dia en bordes)
   int y=s.year;
   int dMar=31;while(dMar>24&&DowOf(y,3,dMar)!=0)dMar--;
   int dOct=31;while(dOct>24&&DowOf(y,10,dOct)!=0)dOct--;
   int secondSunMar=1+((7-DowOf(y,3,1))%7)+7;
   int firstSunNov=1+((7-DowOf(y,11,1))%7);
   datetime usA=StructToTime(IntegerToString(y)+".03."+IntegerToString(secondSunMar)+" 00:00");
   datetime usB=StructToTime(IntegerToString(y)+".11."+IntegerToString(firstSunNov)+" 00:00");
   datetime euA=StructToTime(IntegerToString(y)+".03."+IntegerToString(dMar)+" 00:00");
   datetime euB=StructToTime(IntegerToString(y)+".10."+IntegerToString(dOct)+" 00:00");
   bool us=(srv>=usA&&srv<usB);
   bool eu=(srv>=euA&&srv<euB);
   if(us&&!eu)return 6;
   return 7;
  }
void UpdateOffset()
  {
   bool tester=(bool)MQLInfoInteger(MQL_TESTER);
   bool autoOK=InpAutoServerOffset||(tester&&InpTesterOffsetAuto);
   if(!autoOK){g_off=InpServerMinusNYHours;return;}
   datetime gmt=TimeGMT();
   datetime srv=TimeTradeServer();
   if(gmt>D'2000.01.01'&&srv>D'2000.01.01')
     {
      int so=(int)MathRound((double)(srv-gmt)/3600.0);
      // servidor IC Markets EU: 2 invierno / 3 verano; NY: -5/-4
      int ny=IsUSDST(gmt)?-4:-5;
      // valida contra EU: si so incoherente, recalcula via regla EU
      int soEU=IsEUDST(gmt)?3:2;
      if(MathAbs(so-soEU)>1)so=soEU;
      int off=so-ny;
      if(off>=5&&off<=8){g_off=off;return;}
     }
   g_off=TesterOffsetTable(srv!=0?srv:TimeCurrent());
  }
datetime NYTime(datetime srv){return srv-g_off*3600;}
int      NYMin(datetime srv){datetime t=NYTime(srv);return (int)((t%86400)/60);}
datetime NYDay(datetime srv){datetime t=NYTime(srv);return t-(t%86400);}
datetime NYDayStartSrv(datetime srv){return NYDay(srv)+g_off*3600;}

//==================== utilidades ====================
double NPr(double p){return NormalizeDouble(MathRound(p/TickSize)*TickSize,SymDigits);}
double NPTick(double p,bool up)
  {
   double t=p/TickSize;
   t=up?MathCeil(t-1e-9):MathFloor(t+1e-9);
   return NormalizeDouble(t*TickSize,SymDigits);
  }
double NormDown(double v)
  {
   if(v<=0)return 0;
   double x=MathFloor((v+1e-9)/VolStep)*VolStep;
   if(x<VolMin-1e-9)return 0;
   x=MathMin(x,VolMax);
   return NormalizeDouble(x,2);
  }
double LotFor(int level)
  {
   double a[4];a[0]=InpLot1;a[1]=InpLot2;a[2]=InpLot3;a[3]=InpLot4;
   int i=MathMax(0,MathMin(level,3));
   return NormDown(MathMin(a[i],MathMin(InpLotCap,VolMax)));
  }
// moneda de la cuenta que se gana/pierde con 1.0 lote y un movimiento de InpUnit
double EPL(int dir,double px)
  {
   double v=0;
   if(!OrderCalcProfit(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,SYM,1.0,px,px+dir*InpUnit,v))return 0;
   return MathAbs(v);
  }

//==================== estado ====================
string GK(string n)
  {
   string s=SYM;StringReplace(s,".","_");StringReplace(s," ","_");
   return "LAD8_"+IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN))+"_"+s+"_"+IntegerToString((int)InpMagic)+"_"+n;
  }
// Las Global Variables son double; dividir ulong evita perder precision del identificador.
void SaveUlongGV(string name,ulong value)
  {
   uint lo=(uint)(value & 0xFFFFFFFF);
   uint hi=(uint)(value >> 32);
   GlobalVariableSet(GK(name+"_LO"),(double)lo);
   GlobalVariableSet(GK(name+"_HI"),(double)hi);
  }
ulong LoadUlongGV(string name)
  {
   if(!GlobalVariableCheck(GK(name+"_LO"))||!GlobalVariableCheck(GK(name+"_HI")))return 0;
   uint lo=(uint)GlobalVariableGet(GK(name+"_LO"));
   uint hi=(uint)GlobalVariableGet(GK(name+"_HI"));
   return (((ulong)hi)<<32)|(ulong)lo;
  }
void SaveState()
  {
   if(MQLInfoInteger(MQL_TESTER))return;
   GlobalVariableSet(GK("LEVEL"),g_level);GlobalVariableSet(GK("CD"),g_cd);GlobalVariableSet(GK("WINS"),g_wins);
   GlobalVariableSet(GK("CYC"),g_cyclePL);GlobalVariableSet(GK("DAY"),g_dayPL);
   GlobalVariableSet(GK("KEY"),(double)g_dayKey);GlobalVariableSet(GK("STOP"),g_stopped?1:0);
   GlobalVariableSet(GK("BIAS"),g_bias);GlobalVariableSet(GK("BDONE"),g_biasDone?1:0);
   SaveUlongGV("POS",g_posId);GlobalVariableSet(GK("CACT"),g_cycleActive?1:0);
   GlobalVariableSet(GK("M15H"),g_m15Hi);GlobalVariableSet(GK("M15L"),g_m15Lo);
  }
void LoadState()
  {
   if(MQLInfoInteger(MQL_TESTER))return;
   if(!GlobalVariableCheck(GK("LEVEL")))return;
   g_level=(int)GlobalVariableGet(GK("LEVEL"));g_cd=(int)GlobalVariableGet(GK("CD"));g_wins=(int)GlobalVariableGet(GK("WINS"));
   g_cyclePL=GlobalVariableGet(GK("CYC"));g_dayPL=GlobalVariableGet(GK("DAY"));
   g_dayKey=(datetime)GlobalVariableGet(GK("KEY"));g_stopped=(GlobalVariableGet(GK("STOP"))>0.5);
   g_bias=(int)GlobalVariableGet(GK("BIAS"));g_biasDone=(GlobalVariableGet(GK("BDONE"))>0.5);
   g_posId=LoadUlongGV("POS");
   g_cycleActive=(GlobalVariableGet(GK("CACT"))>0.5);
   g_m15Hi=GlobalVariableGet(GK("M15H"));g_m15Lo=GlobalVariableGet(GK("M15L"));
  }

//==================== posiciones ====================
bool SelectMine(ulong &ticket)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);if(t==0)continue;
      if(PositionGetString(POSITION_SYMBOL)==SYM&&(ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic){ticket=t;return true;}
     }
   return false;
  }
bool HavePosition(){ulong t;return SelectMine(t);}
bool HaveForeignPosition()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);if(t==0)continue;
      if(PositionGetString(POSITION_SYMBOL)==SYM&&(ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic)return true;
     }
   return false;
  }

void EndCycle(string why)
  {
   PrintFormat("CICLO FIN (%s): P/L ciclo=%.2f dia=%.2f",why,g_cyclePL,g_dayPL);
   g_level=0;g_cyclePL=0;g_cd=InpCooldownBars;g_cycleActive=false;
   if(NYMin(TimeCurrent())>=InpNYEndMin)g_stopped=true;   // fuera de ventana: no hay escalera nueva
   SaveState();
  }

// false si el historial aun no esta disponible
bool OnPositionGone()
  {
   if(g_posId==0)return true;
   bool have=HistorySelectByPosition(g_posId);
   double pl=0;int outs=0;
   if(have)
     {
      for(int i=0;i<HistoryDealsTotal();i++)
        {
         ulong t=HistoryDealGetTicket(i);if(t==0)continue;
         if(HistoryDealGetString(t,DEAL_SYMBOL)!=SYM||(ulong)HistoryDealGetInteger(t,DEAL_MAGIC)!=InpMagic)continue;   // solo deals de este EA y simbolo
         pl+=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)+HistoryDealGetDouble(t,DEAL_COMMISSION)+HistoryDealGetDouble(t,DEAL_FEE);
         long e=HistoryDealGetInteger(t,DEAL_ENTRY);
         if(e==DEAL_ENTRY_OUT||e==DEAL_ENTRY_INOUT||e==DEAL_ENTRY_OUT_BY)outs++;
        }
     }
   if(!have||outs==0)
     {
      if(g_goneSince==0)g_goneSince=TimeCurrent();
      if(TimeCurrent()-g_goneSince>InpHistTimeoutSec)
        {
         if((bool)MQLInfoInteger(MQL_TESTER))
           {
            PrintFormat("TESTER: historial posicion %I64u aun no disponible tras %d s, reintentando sin parar el dia.",g_posId,InpHistTimeoutSec);
            return false;
           }
         PrintFormat("ALERTA: historial de la posicion %I64u no disponible tras %d s. Se para el EA por hoy: revisa el resultado a mano.",g_posId,InpHistTimeoutSec);
         g_posId=0;g_goneSince=0;
         EndCycle("HISTORIAL_NO_DISPONIBLE");g_stopped=true;SaveState();
         return true;
        }
      return false;
     }
   g_goneSince=0;
   g_posId=0;
   g_dayPL+=pl;g_cyclePL+=pl;
   PrintFormat("OPERACION CERRADA L%d: P/L=%.2f ciclo=%.2f dia=%.2f",g_level+1,pl,g_cyclePL,g_dayPL);
   if(g_cyclePL>=InpTargetEUR-InpTargetTolEUR){g_wins++;EndCycle("OBJETIVO");}
   else
     {
      g_cd=InpCooldownBars;
      g_level++;                                   // ciclo no recuperado del todo: siguiente nivel
      if(g_level>=MathMin(InpLevels,4)){EndCycle("MAX_NIVEL");g_stopped=true;}
     }
   if(-g_dayPL>=InpMaxDailyLoss)g_stopped=true;
   if(g_wins>=InpMaxWinsPerDay)g_stopped=true;
   SaveState();
   return true;
  }

void EnforceHardStop()
  {
   ulong tk;if(!SelectMine(tk))return;
   datetime now=TimeCurrent();
   datetime pd=(datetime)PositionGetInteger(POSITION_TIME);
   bool oldDay=(NYDay(pd)!=NYDay(now));
   if(NYMin(now)>=InpHardStopNYMin||oldDay)
     {
      if(!Trade.PositionClose(tk))
         PrintFormat("HARD STOP FALLIDO ticket %I64u: %s (retcode %u). Se reintenta en el siguiente tick.",tk,Trade.ResultRetcodeDescription(),Trade.ResultRetcode());
      else Print("HARD STOP: posicion cerrada");
     }
  }

//==================== sesgo 09:25 NY ====================
bool ComputeBias(datetime now)
  {
   datetime base=NYDayStartSrv(now);
   datetime tb=base+InpBiasNYMin*60;
   datetime tl=base+InpLondonStartNYMin*60;
   datetime tv=base+InpBiasVWAPFromNYMin*60;

   MqlRates a[];
   datetime te=base+InpLondonEndNYMin*60;
   int n=CopyRates(SYM,PERIOD_M1,tl,te-1,a);
   if(n<10)return false;
   double hi=-DBL_MAX,lo=DBL_MAX;
   for(int i=0;i<n;i++){hi=MathMax(hi,a[i].high);lo=MathMin(lo,a[i].low);}
   double op=a[0].open;
   MqlRates p1[];
   if(CopyRates(SYM,PERIOD_M1,tb-120,tb-1,p1)<1)return false;
   double price=p1[ArraySize(p1)-1].close;

   MqlRates v[];
   int m=CopyRates(SYM,PERIOD_M1,tv,tb-1,v);
   if(m<10)return false;
   double pv=0,vs=0;
   for(int i=0;i<m;i++)
     {
      double vol=(double)v[i].tick_volume;if(vol<1)vol=1;
      pv+=((v[i].high+v[i].low+v[i].close)/3.0)*vol;vs+=vol;
     }
   double vwap=pv/vs;

   MqlRates m15[];
   int k=CopyRates(SYM,PERIOD_M15,tb-3600,tb-900,m15);
   if(k>=2){g_m15Hi=MathMax(m15[k-1].high,m15[k-2].high);g_m15Lo=MathMin(m15[k-1].low,m15[k-2].low);}
   else if(InpUseM15)return false;

   double refL,refS;
   if(InpLondonRef==LON_RANGE){refL=hi;refS=lo;}
   else if(InpLondonRef==LON_OPEN){refL=op;refS=op;}
   else{refL=(hi+lo)/2.0;refS=refL;}

   g_bias=0;
   if(InpBiasAllowVWAPOnly)
     {
      // v8.06: sesgo SOLO por precio vs VWAP, ignora Londres
      if(price>vwap)g_bias=1;
      else if(price<vwap)g_bias=-1;
      g_bLon=refL;  // still compute for log, but not used for bias
      PrintFormat("SESGO 09:25 NY (VWAP-ONLY): precio=%.2f VWAP=%.2f -> %s",price,vwap,g_bias>0?"COMPRAS":(g_bias<0?"VENTAS":"SIN OPERAR"));
     }
   else
     {
      if(price>vwap&&price>refL)g_bias=1;
      else if(price<vwap&&price<refS)g_bias=-1;
      g_bLon=(g_bias<0?refS:refL);
      PrintFormat("SESGO 09:25 NY: precio=%.2f Londres=%.2f VWAP=%.2f -> %s",price,g_bLon,vwap,g_bias>0?"COMPRAS":(g_bias<0?"VENTAS":"SIN OPERAR"));
     }
   g_bPrice=price;g_bVWAP=vwap;
   g_biasDone=true;
   SaveState();
   return true;
  }

//==================== VWAP senal ====================
double CalcVWAP(datetime lastClosed)
  {
   datetime anchor=NYDayStartSrv(lastClosed)+InpSigVWAPAnchorNYMin*60;
   if(anchor>lastClosed)return 0;
   MqlRates b[];
   int got=CopyRates(SYM,PERIOD_M1,anchor,lastClosed,b);
   if(got<=0)return 0;
   double pv=0,v=0;
   for(int i=0;i<got;i++)
     {
      double vol=(double)b[i].tick_volume;if(vol<1)vol=1;
      pv+=((b[i].high+b[i].low+b[i].close)/3.0)*vol;v+=vol;
     }
   return v>0?pv/v:0;
  }

//==================== entrada ====================
// 1 = abierta, -1 = fallo transitorio, -2 = sin presupuesto (termina escalera)
int OpenLevel(int dir)
  {
   MqlTick q;if(!SymbolInfoTick(SYM,q))return -1;
   double px=(dir>0?q.ask:q.bid);
   double lot=LotFor(g_level);
   double epl=EPL(dir,px);
   if(lot<=0||epl<=0)return -1;

   double sprPts=(q.ask-q.bid)/InpUnit;
   double worst=lot*epl*(InpSLPts+InpSlipPts+sprPts)+lot*InpCommissionPerLot;   // perdida maxima de ESTE nivel (incluye comision)
   double cum=MathMax(0.0,-g_cyclePL);                     // perdida acumulada de la escalera
   if(cum+worst>InpMaxLadderLoss||(-g_dayPL)+worst>InpMaxDailyLoss)
     {g_endReason="TOPE_RIESGO";PrintFormat("TOPE RIESGO: acumulado %.2f + nivel %.2f supera el tope",cum,worst);return -2;}

   // dinero que falta para dejar el ciclo en +objetivo (sirve con ciclo negativo, cero o parcialmente positivo)
   double need=InpTargetEUR-g_cyclePL+lot*InpCommissionPerLot;
   double tpPts=need/(lot*epl);

   // TP minimo aceptable por el broker: si falta muy poco, se pasa un poco del objetivo en vez de bloquear la escalera
   double stopsMin=(double)SymbolInfoInteger(SYM,SYMBOL_TRADE_STOPS_LEVEL)*SymbolInfoDouble(SYM,SYMBOL_POINT);
   double minTPPts=(stopsMin+TickSize)/InpUnit;
   if(tpPts<minTPPts)tpPts=minTPPts;

   if(tpPts>InpMaxTPPts){g_endReason="TP_NECESARIO_EXCESIVO";PrintFormat("TP necesario %.1f ticks > maximo %.1f ticks",tpPts,InpMaxTPPts);return -2;}
   if(InpSLPts*InpUnit<stopsMin)return -1;

   if(InpMaxMarginUsePct>0)
     {
      double margin=0;
      if(!OrderCalcMargin(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,SYM,lot,px,margin)||margin<=0)return -1;
      if(margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*InpMaxMarginUsePct/100.0)return -1;
     }

   double sl=NPTick(px-dir*InpSLPts*InpUnit,dir<0);
   double tp=NPTick(px+dir*tpPts*InpUnit,dir>0);
   bool ok=(dir>0)?Trade.Buy(lot,SYM,0,sl,tp,"LAD8"):Trade.Sell(lot,SYM,0,sl,tp,"LAD8");
   uint rc=Trade.ResultRetcode();
   if(!ok||!(rc==TRADE_RETCODE_DONE||rc==TRADE_RETCODE_DONE_PARTIAL))
     {Print("ORDEN FALLIDA: ",Trade.ResultRetcodeDescription());return -1;}

   ulong tk=0;
   for(int z=0;z<10&&!SelectMine(tk);z++)Sleep(50);
   if(tk==0)
     {
      Print("CRITICO: orden aceptada pero no se pudo identificar la posicion. EA detenido por hoy.");
      g_stopped=true;SaveState();return -1;
     }
   g_posId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);g_cycleActive=true;
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl2=NPTick(open-dir*InpSLPts*InpUnit,dir<0),tp2=NPTick(open+dir*tpPts*InpUnit,dir>0);
   for(int a2=0;a2<3;a2++)
     {
      if(!SelectMine(tk))break;
      if(MathAbs(sl2-PositionGetDouble(POSITION_SL))<TickSize&&MathAbs(tp2-PositionGetDouble(POSITION_TP))<TickSize)break;
      if(!Trade.PositionModify(tk,sl2,tp2))Sleep(150);
     }
   if(SelectMine(tk))
     {
      double liveSL=PositionGetDouble(POSITION_SL),liveTP=PositionGetDouble(POSITION_TP);
      if(liveSL<=0||liveTP<=0)
        {
         bool cl=false;
         for(int c=0;c<5&&!cl;c++){cl=Trade.PositionClose(tk);if(!cl)Sleep(150);}
         PrintFormat("SEGURIDAD: proteccion incompleta SL=%.5f TP=%.5f, cierre %s (%s)",liveSL,liveTP,cl?"OK":"FALLIDO",Trade.ResultRetcodeDescription());
         if(!cl){g_stopped=true;SaveState();}
         return -1;
        }
     }
   PrintFormat("ABIERTA L%d %s lote=%.2f SL=%.1f ticks TP=%.1f ticks (objetivo ciclo %.2f, perdida max nivel %.2f)",g_level+1,dir>0?"BUY":"SELL",lot,InpSLPts,tpPts,InpTargetEUR,worst);
   SaveState();
   return 1;
  }

//==================== logica por barra ====================
void NewDayIfNeeded(datetime t)
  {
   datetime dk=NYDay(t);
   if(dk==g_dayKey)return;
   g_dayKey=dk;g_dayPL=0;g_stopped=false;g_cd=0;g_wins=0;g_bias=0;g_biasDone=false;
   if(!HavePosition()&&g_posId==0){g_level=0;g_cyclePL=0;g_cycleActive=false;}
   SaveState();
  }

void ProcessBar()
  {
   UpdateOffset();
   MqlRates r[];ArraySetAsSeries(r,true);
   if(CopyRates(SYM,PERIOD_M1,0,3,r)<3)return;
   NewDayIfNeeded(r[1].time);

   bool pos=HavePosition();
   if(g_posId>0&&!pos){if(!OnPositionGone())return;}
   pos=HavePosition();

   int nyNow=NYMin(r[1].time),nyPrev=NYMin(r[1].time);   // v8.05: todo sobre vela cerrada r[1] (evita cruce de dia en medianoche NY)

   if(!g_biasDone&&nyNow>=InpBiasNYMin&&nyNow<InpHardStopNYMin)ComputeBias(r[1].time);

   if(!pos&&g_cd>0){g_cd--;SaveState();}

   // cierre de seguridad sin posicion: la escalera se da por terminada
   if(!pos&&g_cycleActive&&nyNow>=InpHardStopNYMin){EndCycle("HARD_END");g_stopped=true;}

   if(pos){g_status="Operacion abierta L"+IntegerToString(g_level+1);return;}
   if(g_stopped){g_status="Parado por hoy";return;}
   if(!g_biasDone){g_status="Esperando sesgo 09:25 NY";return;}
   if(g_bias==0){g_status="Sin sesgo: hoy no se opera";return;}

   bool inWin=(nyNow>=InpNYStartMin+1&&nyNow<InpNYEndMin);
   bool allowed=(inWin&&!g_cycleActive)||(g_cycleActive&&nyNow<InpHardStopNYMin);
   if(!g_cycleActive&&!inWin){g_status="Fuera de ventana";return;}   // escalera en curso continua fuera de ventana
   if(!allowed){g_status="Fuera de ventana";return;}
   if(g_cd>0){g_status="Cooldown";return;}
   if(InpBlockForeignPosition&&HaveForeignPosition()){g_status="Otra posicion en el simbolo";return;}

   double spr=SymbolInfoDouble(SYM,SYMBOL_ASK)-SymbolInfoDouble(SYM,SYMBOL_BID);
   if(spr<0||spr>InpMaxSpread*InpUnit){g_status="Spread alto";return;}

   double e9[],e20[];ArraySetAsSeries(e9,true);ArraySetAsSeries(e20,true);
   if(nyPrev<InpNYStartMin||CopyBuffer(hE9,0,0,3,e9)<3||CopyBuffer(hE20,0,0,3,e20)<3)return;
   double vw=CalcVWAP(r[1].time);
   if(vw<=0)return;
   int signal=0;
   if(g_bias>0&&r[1].close>vw&&e9[1]>e20[1]&&e9[1]>e9[2])signal=1;
   if(g_bias<0&&r[1].close<vw&&e9[1]<e20[1]&&e9[1]<e9[2])signal=-1;
   if(InpUseM15&&signal>0&&!(r[1].close>g_m15Hi))signal=0;
   if(InpUseM15&&signal<0&&!(r[1].close<g_m15Lo))signal=0;
   if(signal==0){g_status="Esperando senal a favor del sesgo";return;}

   int res=OpenLevel(signal);
   if(res==-2){EndCycle(g_endReason);g_stopped=true;SaveState();}
   g_status=(res==1?"Abierta L"+IntegerToString(g_level+1):"Reintento");
  }

void Panel()
  {
   string b=(g_bias>0?"COMPRAS":(g_bias<0?"VENTAS":(g_biasDone?"SIN OPERAR":"pendiente")));
   Comment("LADDER v8.05 BIAS\n",
           "Sesgo: ",b,"  (precio ",DoubleToString(g_bPrice,1)," | Londres ",DoubleToString(g_bLon,1)," | VWAP ",DoubleToString(g_bVWAP,1),")\n",
           "Nivel: L",g_level+1,"/",MathMin(InpLevels,4),"  lote ",DoubleToString(LotFor(g_level),2),"\n",
           "P/L ciclo: ",DoubleToString(g_cyclePL,2),"  dia: ",DoubleToString(g_dayPL,2),"  ganados hoy: ",g_wins,"\n",
           "Estado: ",g_status);
  }

//==================== eventos ====================
int OnInit()
  {
   SYM=(InpSymbol==""?_Symbol:InpSymbol);
   if(!SymbolSelect(SYM,true))return INIT_FAILED;
   TickSize=SymbolInfoDouble(SYM,SYMBOL_TRADE_TICK_SIZE);SymDigits=(int)SymbolInfoInteger(SYM,SYMBOL_DIGITS);
   VolMin=SymbolInfoDouble(SYM,SYMBOL_VOLUME_MIN);VolMax=SymbolInfoDouble(SYM,SYMBOL_VOLUME_MAX);VolStep=SymbolInfoDouble(SYM,SYMBOL_VOLUME_STEP);
   if(TickSize<=0||VolStep<=0||InpSLPts<=0||InpTargetEUR<=0||InpLevels<1||InpLevels>4)return INIT_PARAMETERS_INCORRECT;
   long marginMode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("AVISO: cuenta netting/exchange. No uses otro EA ni operaciones manuales en el mismo simbolo.");
   if(InpUnit<=0||MathAbs(MathRound(InpUnit/TickSize)*TickSize-InpUnit)>TickSize*1e-6){Print("ERROR: InpUnit debe ser multiplo de TickSize (",TickSize,")");return INIT_PARAMETERS_INCORRECT;}

   // lotes: secuencia EXACTA 0.1 / 0.2 / 0.3 / 0.4 (y que el broker los acepte tal cual)
   double lotIn[4];lotIn[0]=InpLot1;lotIn[1]=InpLot2;lotIn[2]=InpLot3;lotIn[3]=InpLot4;
   for(int l=0;l<MathMin(InpLevels,4);l++)
     {
      double want=0.1*(l+1);
      if(MathAbs(lotIn[l]-want)>1e-9||MathAbs(LotFor(l)-want)>1e-9)
        {PrintFormat("ERROR: el lote del nivel %d debe ser exactamente %.1f (input=%.2f, efectivo=%.2f; min=%.2f paso=%.2f max=%.2f cap=%.2f)",l+1,want,lotIn[l],LotFor(l),VolMin,VolStep,VolMax,InpLotCap);return INIT_PARAMETERS_INCORRECT;}
     }
   if(InpLotCap<0.4-1e-9){Print("ERROR: InpLotCap debe ser >= 0.4");return INIT_PARAMETERS_INCORRECT;}
   if(InpSlipPts<0||InpMaxSpread<=0||InpMaxTPPts<=0||InpMaxLadderLoss<=0||InpMaxDailyLoss<=0||InpMaxWinsPerDay<1||InpCommissionPerLot<0||InpTargetTolEUR<0||InpHistTimeoutSec<1)
     {Print("ERROR: parametros de riesgo invalidos");return INIT_PARAMETERS_INCORRECT;}
   if(InpBiasNYMin<0||InpBiasNYMin>=1440||InpLondonStartNYMin<0||InpLondonEndNYMin>1440||InpLondonStartNYMin>=InpLondonEndNYMin||
      InpNYStartMin<0||InpNYEndMin>1440||InpNYStartMin>=InpNYEndMin||InpHardStopNYMin<=InpNYEndMin||InpHardStopNYMin>1440)
     {Print("ERROR: horarios NY invalidos");return INIT_PARAMETERS_INCORRECT;}
   if(InpSigVWAPAnchorNYMin<0||InpSigVWAPAnchorNYMin>=1440||InpBiasVWAPFromNYMin>=InpBiasNYMin)
     {Print("ERROR: anchors VWAP invalidos");return INIT_PARAMETERS_INCORRECT;}

   hE9=iMA(SYM,PERIOD_M1,9,0,MODE_EMA,PRICE_CLOSE);hE20=iMA(SYM,PERIOD_M1,20,0,MODE_EMA,PRICE_CLOSE);
   if(hE9==INVALID_HANDLE||hE20==INVALID_HANDLE)return INIT_FAILED;

   Trade.SetExpertMagicNumber(InpMagic);Trade.SetDeviationInPoints(InpDeviation);
   Trade.SetTypeFillingBySymbol(SYM);Trade.SetAsyncMode(false);
   UpdateOffset();LoadState();
   lastbar=iTime(SYM,PERIOD_M1,0);

//--- warmup v8.05: diagnostico de datos y viabilidad (no cambia logica)
   int barsM1=Bars(SYM,PERIOD_M1),barsM15=Bars(SYM,PERIOD_M15);
   PrintFormat("LADDER v8.05 warmup: Bars M1=%d M15=%d | offset servidor-NY=%d (auto=%s testerAuto=%s)",barsM1,barsM15,g_off,InpAutoServerOffset?"on":"off",InpTesterOffsetAuto?"on":"off");
   if(barsM1<500)Print("AVISO warmup: pocas barras M1 (<500), sesgo/VWAP poco fiables al inicio.");
   if(InpUseM15&&barsM15<200)Print("AVISO warmup: pocas barras M15 (<200) con InpUseM15=true.");
   MqlRates chk[];int chkM1=CopyRates(SYM,PERIOD_M1,0,5,chk);
   if(chkM1<5)Print("AVISO warmup: CopyRates M1 devolvio <5, posible historial incompleto.");

   double ask=SymbolInfoDouble(SYM,SYMBOL_ASK),epl=EPL(1,ask);
   double units=0;for(int l=0;l<MathMin(InpLevels,4);l++)units+=LotFor(l);
   PrintFormat("LADDER v8.05: valor 1 lote x 1 tick EA=%.4f | TickSize=%.4f InpUnit=%.4f (ratio %.2f) | suma lotes=%.2f | perdida maxima escalera ~ %.2f (tope %.0f)",epl,TickSize,InpUnit,InpUnit/TickSize,units,units*epl*(InpSLPts+InpSlipPts),InpMaxLadderLoss);
   double lot1=LotFor(0);
   double stopsMin0=(double)SymbolInfoInteger(SYM,SYMBOL_TRADE_STOPS_LEVEL)*SymbolInfoDouble(SYM,SYMBOL_POINT);
   PrintFormat("LADDER v8.05: 1 tick EA = %.4f de precio | SL=%.2f | spread max=%.2f | slippage=%.2f | stops level=%.2f (todo en precio)",InpUnit,InpSLPts*InpUnit,InpMaxSpread*InpUnit,InpSlipPts*InpUnit,stopsMin0);
   if(epl>0&&lot1>0)
     {
      double tp1=InpTargetEUR/(lot1*epl);
      PrintFormat("LADDER v8.05: TP necesario en nivel 1 = %.1f ticks (%.2f de precio) | maximo permitido %.1f ticks",tp1,tp1*InpUnit,InpMaxTPPts);
      if(tp1>InpMaxTPPts)Print("AVISO: el nivel 1 necesita mas TP que InpMaxTPPts, el EA no abrira ninguna escalera. Ajusta lotes, InpTargetEUR o InpMaxTPPts.");
     }
   if(InpSLPts*InpUnit<stopsMin0)Print("AVISO: el SL es menor que el nivel minimo de stops del broker, el EA no podra abrir operaciones.");
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   datetime b=iTime(SYM,PERIOD_M1,0);
   if(g_posId>0&&!HavePosition())OnPositionGone();
   EnforceHardStop();
   if(b!=0&&b!=lastbar){lastbar=b;ProcessBar();}
   Panel();
  }

void OnDeinit(const int reason)
  {
   SaveState();
   if(hE9!=INVALID_HANDLE)IndicatorRelease(hE9);
   if(hE20!=INVALID_HANDLE)IndicatorRelease(hE20);
   Comment("");
  }
//+------------------------------------------------------------------+
