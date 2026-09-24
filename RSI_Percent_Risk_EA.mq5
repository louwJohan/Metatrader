// Native MQL5. See README.md for execution and recovery semantics.
#property strict
#property version "1.00"
#include <Trade/Trade.mqh>

enum ENUM_SIZE_MODE
  {
   SIZE_BALANCE_PERCENT=0,
   SIZE_ACCOUNT_CURRENCY=1,
   SIZE_FIXED_LOTS=2
  };

input group "Identity and signals"
input ulong InpMagicNumber=26092401;
input ENUM_TIMEFRAMES InpRSITimeframe=PERIOD_H1;
input int InpRSIPeriod=14;
input double InpBuyThreshold=30.0;
input double InpSellThreshold=70.0;
input bool InpEnableBuys=true;
input bool InpEnableSells=true;

input group "Moving average filter"
input bool InpUseMAFilter=false;
input int InpMAPeriod=50;
input ENUM_TIMEFRAMES InpMATimeframe=PERIOD_D1;
input ENUM_MA_METHOD InpMAMethod=MODE_SMA;

input group "Position size"
input ENUM_SIZE_MODE InpSizeMode=SIZE_BALANCE_PERCENT;
input double InpRiskBalancePercent=1.0;
input double InpRiskAccountCurrency=100.0;
input double InpFixedLots=0.10;

input group "Stops: percent of actual entry price"
input double InpStopLossPercent=5.0;
input double InpTakeProfitPercent=1.0;
input bool InpUseTrailingStop=true;
input double InpTrailTriggerPercent=0.5;
input double InpTrailDistancePercent=0.1;
input double InpTrailStepPercent=0.05;

input group "Execution"
input uint InpDeviationPoints=10;
input int InpMaxSpreadPoints=0; // 0: disabled
input int InpMaxOwnPositions=0; // 0: unlimited, across both directions

CTrade trade;
int rsi_handle=INVALID_HANDLE,ma_handle=INVALID_HANDLE;
int state_file=INVALID_HANDLE;
bool testing=false,ready=false,buy_armed=true,sell_armed=true;
datetime last_bar=0,last_manage=0;
double tick_size=0,point_size=0;
int digits_count=0;
ulong trail_active[];
struct VerifiedFill
  {
   ulong identifier;
   double entry;
  };
VerifiedFill verified_fills[];
const long JOURNAL_SALT=734951027;

bool FillVerified(const ulong identifier,const double entry)
  {
   for(int i=0;i<ArraySize(verified_fills);i++)
      if(verified_fills[i].identifier==identifier && verified_fills[i].entry==entry) return true;
   return false;
  }

void RememberFill(const ulong identifier,const double entry)
  {
   int n=ArraySize(verified_fills);
   for(int i=0;i<n;i++)
      if(verified_fills[i].identifier==identifier) { verified_fills[i].entry=entry; return; }
   if(ArrayResize(verified_fills,n+1)!=n+1) return;
   verified_fills[n].identifier=identifier;
   verified_fills[n].entry=entry;
  }

uint HashText(const string value)
  {
   uint h=2166136261;
   for(int i=0;i<StringLen(value);i++)
      h=(h^(uint)StringGetCharacter(value,i))*16777619;
   return h;
  }

// One exclusive file handle also prevents duplicate instances in this terminal.
// Records contain timestamp/position ID, flags, checksum. Corruption blocks startup.
bool SaveRecord(const long stamp,const long flags)
  {
   if(testing) return true;
   ResetLastError();
   uint a=FileWriteLong(state_file,stamp);
   uint b=FileWriteLong(state_file,flags);
   uint c=FileWriteLong(state_file,stamp^flags^JOURNAL_SALT);
   FileFlush(state_file);
   if(a!=8 || b!=8 || c!=8 || GetLastError()!=0)
     {
      Print("State write failed. New entries disabled until restart.");
      ready=false;
      return false;
     }
   return true;
  }

bool SaveState()
  {
   return SaveRecord((long)last_bar,(buy_armed ? 1 : 0)+(sell_armed ? 2 : 0));
  }

bool TrailIsActive(const ulong identifier)
  {
   for(int i=0;i<ArraySize(trail_active);i++) if(trail_active[i]==identifier) return true;
   return false;
  }

bool ActivateTrail(const ulong identifier,const bool persist)
  {
   if(TrailIsActive(identifier)) return true;
   if(persist && !SaveRecord((long)identifier,4)) return false;
   int n=ArraySize(trail_active);
   if(ArrayResize(trail_active,n+1)!=n+1) return false;
   trail_active[n]=identifier;
   return true;
  }

bool LoadState()
  {
   if(testing) return true; // clean state for every optimizer/test pass
   string name=StringFormat("RSIPct_v1_%I64d_%08X_%08X_%I64u.bin",
                AccountInfoInteger(ACCOUNT_LOGIN),HashText(AccountInfoString(ACCOUNT_SERVER)),
                HashText(_Symbol),InpMagicNumber);
   state_file=FileOpen(name,FILE_READ|FILE_WRITE|FILE_BIN);
   if(state_file==INVALID_HANDLE)
     {
      Print("Cannot lock state file. Check duplicate symbol/magic instances and file permissions: ",GetLastError());
      return false;
     }
   ulong size=FileSize(state_file),valid=0;
   bool damaged=false;
   while(FileTell(state_file)+24<=size)
     {
      long stamp=FileReadLong(state_file),flags=FileReadLong(state_file),check=FileReadLong(state_file);
      if(stamp<0 || flags<0 || flags>4 || check!=(stamp^flags^JOURNAL_SALT))
        { damaged=true; break; }
      if(flags==4)
        {
         if(!ActivateTrail((ulong)stamp,false)) return false;
        }
      else
        {
         last_bar=(datetime)stamp;
         buy_armed=((flags&1)!=0);
         sell_armed=((flags&2)!=0);
        }
      valid=FileTell(state_file);
     }
   if(valid!=size) damaged=true;
   FileSeek(state_file,0,SEEK_END);
   if(damaged)
     {
      // Do not trade with an ambiguous journal; preserve it for diagnosis.
      Print("State journal damaged. Restore backup or use a new magic after reviewing existing positions.");
      return false;
     }
   if(size==0)
     {
      // Missing journal with previous activity: never assume both sides are armed.
      if(!HistorySelect(0,TimeCurrent())) return false;
      for(int i=0;i<HistoryDealsTotal();i++)
        {
         ulong deal=HistoryDealGetTicket(i);
         if(HistoryDealGetString(deal,DEAL_SYMBOL)==_Symbol &&
            (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)==InpMagicNumber)
           { buy_armed=false; sell_armed=false; break; }
        }
      for(int i=0;i<PositionsTotal();i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket>0 && PositionGetString(POSITION_SYMBOL)==_Symbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
           { buy_armed=false; sell_armed=false; break; }
        }
     }
   return true;
  }

bool Owned(const ulong ticket)
  {
   return PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber;
  }

double RoundPrice(const double price,const bool upward)
  {
   double units=price/tick_size;
   return NormalizeDouble((upward ? MathCeil(units-1e-9) : MathFloor(units+1e-9))*tick_size,digits_count);
  }

void InitialStops(const bool buy,const double entry,double &sl,double &tp)
  {
   sl=0; tp=0;
   // Round initial SL toward entry to avoid increasing the planned risk.
   if(InpStopLossPercent>0)
      sl=RoundPrice(entry*(1+(buy ? -1 : 1)*InpStopLossPercent/100.0),buy);
   if(InpTakeProfitPercent>0)
      tp=RoundPrice(entry*(1+(buy ? 1 : -1)*InpTakeProfitPercent/100.0),!buy);
  }

bool StopsValid(const bool buy,const double sl,const double tp,const MqlTick &quote,const bool modifying)
  {
   long level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(modifying) level=(long)MathMax(level,SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL));
   double gap=MathMax((double)level*point_size,tick_size);
   double price=(buy ? quote.bid : quote.ask);
   if(sl!=0 && (sl<=0 || (buy ? price-sl : sl-price)<gap-1e-10)) return false;
   if(tp!=0 && (tp<=0 || (buy ? tp-price : price-tp)<gap-1e-10)) return false;
   return true;
  }

bool CanTrade()
  {
   return TerminalInfoInteger(TERMINAL_CONNECTED) && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
          MQLInfoInteger(MQL_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) &&
          AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
  }

bool PendingOwnOrder()
  {
   for(int i=0;i<OrdersTotal();i++)
     {
      if(OrderGetTicket(i)==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol && (ulong)OrderGetInteger(ORDER_MAGIC)==InpMagicNumber)
         return true;
     }
   return false;
  }

double DirectionUsed(const bool buy)
  {
   // Broker volume limits include every strategy on the account: read only.
   double used=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      if(PositionGetTicket(i)==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)==buy)
         used+=PositionGetDouble(POSITION_VOLUME);
     }
   for(int i=0;i<OrdersTotal();i++)
     {
      if(OrderGetTicket(i)==0 || OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool is_buy=(type==ORDER_TYPE_BUY || type==ORDER_TYPE_BUY_LIMIT ||
                   type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT);
      if(is_buy==buy) used+=OrderGetDouble(ORDER_VOLUME_CURRENT);
     }
   return used;
  }

double CalculateVolume(const bool buy,const double entry,const double sl)
  {
   double minimum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maximum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(minimum<=0 || maximum<minimum || step<=0) return 0;
   double volume=InpFixedLots;
   if(InpSizeMode!=SIZE_FIXED_LOTS)
     {
      double budget=(InpSizeMode==SIZE_ACCOUNT_CURRENCY ? InpRiskAccountCurrency :
                     AccountInfoDouble(ACCOUNT_BALANCE)*InpRiskBalancePercent/100.0);
      double profit=0;
      if(sl<=0 || !OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,
                                   minimum,entry,sl,profit) || profit>=0) return 0;
      volume=budget/(-profit/minimum);
     }
   double limit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
   if(limit>0) maximum=MathMin(maximum,MathMax(0,limit-DirectionUsed(buy)));
   volume=NormalizeDouble(MathFloor(MathMin(volume,maximum)/step+1e-10)*step,8);
   // Never round up to the broker minimum when that would exceed the budget.
   if(volume<minimum-1e-10) return 0;
   return volume;
  }

bool FillingPolicy(ENUM_ORDER_TYPE_FILLING &filling)
  {
   long flags=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((flags&SYMBOL_FILLING_FOK)!=0) { filling=ORDER_FILLING_FOK; return true; }
   if((flags&SYMBOL_FILLING_IOC)!=0) { filling=ORDER_FILLING_IOC; return true; }
   if(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE)!=SYMBOL_TRADE_EXECUTION_MARKET)
     { filling=ORDER_FILLING_RETURN; return true; }
   return false;
  }

void Enter(const bool buy,const double ma)
  {
   if(!ready || !CanTrade() || PendingOwnOrder()) return;
   int count=0;
   for(int i=0;i<PositionsTotal();i++) if(Owned(PositionGetTicket(i))) count++;
   if(InpMaxOwnPositions>0 && count>=InpMaxOwnPositions) return;
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.ask<=0 || quote.bid<=0) return;
   if(InpMaxSpreadPoints>0 && quote.ask-quote.bid>InpMaxSpreadPoints*point_size) return;
   double entry=(buy ? quote.ask : quote.bid);
   if(InpUseMAFilter && (buy ? entry<=ma : entry>=ma)) return;
   double sl,tp;
   InitialStops(buy,entry,sl,tp);
   if(!StopsValid(buy,sl,tp,quote,false))
     { Print("Entry skipped: percentage stops violate broker distance rules."); return; }
   double volume=CalculateVolume(buy,entry,sl);
   if(volume<=0) { Print("Entry skipped: no valid volume within sizing/volume limits."); return; }
   MqlTradeRequest request={};
   MqlTradeResult result={};
   MqlTradeCheckResult check={};
   request.action=TRADE_ACTION_DEAL;
   request.symbol=_Symbol;
   request.magic=InpMagicNumber;
   request.type=(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   request.volume=volume;
   request.price=entry;
   request.sl=sl; request.tp=tp;
   request.deviation=InpDeviationPoints;
   request.comment="RSI percent risk";
   if(!FillingPolicy(request.type_filling)) return;
   if(!OrderCheck(request,check))
     { PrintFormat("Entry check failed: %u %s",check.retcode,check.comment); return; }
   // Durable intent BEFORE sending: a crash/timeout must never cause a duplicate.
   if(buy) buy_armed=false; else sell_armed=false;
   if(!SaveState()) return;
   bool sent=OrderSend(request,result);
   PrintFormat("Entry request: sent=%s retcode=%u order=%I64u deal=%I64u %s",
               sent ? "true" : "false",result.retcode,result.order,result.deal,result.comment);
   // Deliberately retain disarm even after rejection. Do not retry ambiguous orders.
  }

void ManagePositions()
  {
   if(!CanTrade()) return;
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0 || quote.ask<=0) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(!Owned(ticket)) continue;
      bool buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      ulong identifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(InpUseMAFilter && !FillVerified(identifier,entry))
        {
         // Verify actual fill against the last MA bar closed at the entry time.
         // A market fill can slip across the filter after the pre-send quote check.
         datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
         int entry_shift=iBarShift(_Symbol,InpMATimeframe,opened,false);
         double entry_ma;
         if(entry_shift>=0 && ReadValue(ma_handle,entry_shift+1,entry_ma))
           {
            if(buy ? entry<=entry_ma : entry>=entry_ma)
              {
               if(!Owned(ticket)) continue;
               bool closed=trade.PositionClose(ticket);
               uint close_code=trade.ResultRetcode();
               PrintFormat("MA fill violation; close %I64u: sent=%s retcode=%u %s",ticket,
                           closed ? "true" : "false",close_code,trade.ResultRetcodeDescription());
               continue;
              }
            RememberFill(identifier,entry);
           }
        }
      double old_sl=PositionGetDouble(POSITION_SL),old_tp=PositionGetDouble(POSITION_TP);
      double sl,tp;
      InitialStops(buy,entry,sl,tp);
      // Never loosen an existing stop, including one recovered after restart.
      if(old_sl>0 && (sl==0 || (buy ? old_sl>sl : old_sl<sl))) sl=old_sl;
      double price=(buy ? quote.bid : quote.ask);
      double gain=(buy ? price-entry : entry-price);
      bool active=TrailIsActive(identifier);
      if(InpUseTrailingStop && !active && gain>=entry*InpTrailTriggerPercent/100.0)
         active=ActivateTrail(identifier,true);
      if(InpUseTrailingStop && active)
        {
         double trail=RoundPrice(price+(buy ? -1 : 1)*entry*InpTrailDistancePercent/100.0,!buy);
         double step=MathMax(tick_size,entry*InpTrailStepPercent/100.0);
         bool improves=(old_sl==0 || (buy ? trail-old_sl : old_sl-trail)>=step-1e-10);
         if(improves && (sl==0 || (buy ? trail>sl : trail<sl))) sl=trail;
        }
      if(MathAbs(sl-old_sl)<tick_size/2 && MathAbs(tp-old_tp)<tick_size/2) continue;
      if(!StopsValid(buy,sl,tp,quote,true)) continue;
      // Select again immediately before a ticket-specific modification.
      if(!Owned(ticket)) continue;
      bool ok=trade.PositionModify(ticket,sl,tp);
      uint code=trade.ResultRetcode();
      if(!ok || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_NO_CHANGES))
         PrintFormat("Stop modification failed for %I64u: %u %s",ticket,code,trade.ResultRetcodeDescription());
     }
  }

bool ReadValue(const int handle,const int shift,double &value)
  {
   double buffer[1];
   if(CopyBuffer(handle,0,shift,1,buffer)!=1 || buffer[0]==EMPTY_VALUE ||
      !MathIsValidNumber(buffer[0])) return false;
   value=buffer[0];
   return true;
  }

void EvaluateBar()
  {
   datetime bar=iTime(_Symbol,InpRSITimeframe,0);
   if(bar<=0 || bar<=last_bar || !ready) return;
   double rsi,ma=0;
   if(!ReadValue(rsi_handle,1,rsi)) return;
   if(InpUseMAFilter && !ReadValue(ma_handle,1,ma)) return;
   // Replay only rearming across missed bars. Never place historical entries.
   if(last_bar>0)
     {
      int missed=iBarShift(_Symbol,InpRSITimeframe,last_bar,false);
      if(missed<0) return;
      if(missed>1)
        {
         double old_rsi[];
         int needed=missed-1;
         if(CopyBuffer(rsi_handle,0,2,needed,old_rsi)!=needed) return;
         for(int i=0;i<needed;i++)
           {
            if(old_rsi[i]==EMPTY_VALUE || !MathIsValidNumber(old_rsi[i])) return;
           }
         for(int i=0;i<needed;i++)
           {
            if(old_rsi[i]>50) buy_armed=true;
            if(old_rsi[i]<50) sell_armed=true;
           }
        }
     }
   if(rsi>50) buy_armed=true;
   if(rsi<50) sell_armed=true;
   last_bar=bar;
   if(!SaveState()) return;
   if(InpEnableBuys && buy_armed && rsi<InpBuyThreshold) Enter(true,ma);
   else if(InpEnableSells && sell_armed && rsi>InpSellThreshold) Enter(false,ma);
  }

int OnInit()
  {
   if(InpMagicNumber==0 || InpRSIPeriod<2 || InpMAPeriod<1 ||
      !(InpBuyThreshold>0 && InpBuyThreshold<50) ||
      !(InpSellThreshold>50 && InpSellThreshold<100) ||
      InpStopLossPercent<0 || InpStopLossPercent>=100 ||
      InpTakeProfitPercent<0 || InpTakeProfitPercent>=100 ||
      InpTrailTriggerPercent<0 || InpTrailDistancePercent<0 || InpTrailStepPercent<0 ||
      (InpUseTrailingStop && InpTrailDistancePercent<=0) ||
      InpMaxSpreadPoints<0 || InpMaxOwnPositions<0 ||
      (InpSizeMode==SIZE_FIXED_LOTS && InpFixedLots<=0) ||
      (InpSizeMode!=SIZE_FIXED_LOTS && InpStopLossPercent<=0) ||
      (InpSizeMode==SIZE_BALANCE_PERCENT && (InpRiskBalancePercent<=0 || InpRiskBalancePercent>100)) ||
      (InpSizeMode==SIZE_ACCOUNT_CURRENCY && InpRiskAccountCurrency<=0))
     { Print("Invalid inputs. Risk sizing requires SL > 0; use fixed lots for SL=0."); return INIT_PARAMETERS_INCORRECT; }
   // Magic numbers cannot isolate contributions to a shared net position.
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     { Print("Hedging account required: netting/exchange accounts are blocked to preserve strict ownership."); return INIT_FAILED; }
   testing=(bool)MQLInfoInteger(MQL_TESTER);
   tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   point_size=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   digits_count=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   if(tick_size<=0 || point_size<=0) return INIT_FAILED;
   rsi_handle=iRSI(_Symbol,InpRSITimeframe,InpRSIPeriod,PRICE_CLOSE);
   if(InpUseMAFilter) ma_handle=iMA(_Symbol,InpMATimeframe,InpMAPeriod,0,InpMAMethod,PRICE_CLOSE);
   if(rsi_handle==INVALID_HANDLE || (InpUseMAFilter && ma_handle==INVALID_HANDLE)) return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetAsyncMode(false);
   if(!trade.SetTypeFillingBySymbol(_Symbol)) return INIT_FAILED;
   if(!LoadState()) return INIT_FAILED;
   ready=true;
   if(!SaveState()) return INIT_FAILED;
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   // Broker-side stops remain active while this terminal is offline.
   datetime now=TimeCurrent();
   if(now!=last_manage) { last_manage=now; ManagePositions(); }
   EvaluateBar();
  }

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(transaction.type==TRADE_TRANSACTION_DEAL_ADD && transaction.symbol==_Symbol)
     {
      // Includes late/partial executions; ownership is checked per position.
      ManagePositions();
     }
  }

void OnDeinit(const int reason)
  {
   if(rsi_handle!=INVALID_HANDLE) IndicatorRelease(rsi_handle);
   if(ma_handle!=INVALID_HANDLE) IndicatorRelease(ma_handle);
   if(state_file!=INVALID_HANDLE) { FileClose(state_file); state_file=INVALID_HANDLE; }
  }
