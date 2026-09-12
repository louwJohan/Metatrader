//+------------------------------------------------------------------+
//|                                             SessionHighlighter.mq5 |
//| Highlights Asian, London, and New York trading sessions.          |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

input group "General"
input int  DaysToDisplay = 10;          // Number of completed/current days to shade
input int  FillOpacity   = 38;          // 0 = transparent, 255 = opaque

input group "Asian Session (broker server time)"
input bool  ShowAsian    = true;
input string AsianStart  = "00:00";
input string AsianEnd    = "09:00";
input color AsianColor   = clrDodgerBlue;

input group "London Session (broker server time)"
input bool  ShowLondon   = true;
input string LondonStart = "08:00";
input string LondonEnd   = "17:00";
input color LondonColor  = clrMediumSeaGreen;

input group "New York Session (broker server time)"
input bool  ShowNewYork    = true;
input string NewYorkStart  = "13:00";
input string NewYorkEnd    = "22:00";
input color NewYorkColor   = clrTomato;

string object_prefix = "SessionHighlighter_";

// Convert an HH:MM input into seconds from midnight.
bool ParseClock(const string clock_text, int &seconds_from_midnight)
{
   string parts[];
   if(StringSplit(clock_text, ':', parts) != 2)
      return false;

   int hours = (int)StringToInteger(parts[0]);
   int minutes = (int)StringToInteger(parts[1]);
   if(hours < 0 || hours > 23 || minutes < 0 || minutes > 59)
      return false;

   seconds_from_midnight = hours * 3600 + minutes * 60;
   return true;
}

void DeleteSessionObjects()
{
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, object_prefix) == 0)
         ObjectDelete(0, name);
   }
}

void DrawSession(const string session_name,
                 const datetime day_start,
                 const int start_seconds,
                 const int end_seconds,
                 const color session_color,
                 const double top_price,
                 const double bottom_price)
{
   datetime start_time = day_start + start_seconds;
   datetime end_time = day_start + end_seconds;
   if(end_time <= start_time)
      end_time += 24 * 60 * 60; // Supports sessions that cross midnight.

   string name = object_prefix + session_name + "_" + IntegerToString((int)day_start);
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, start_time, top_price, end_time, bottom_price))
      return;

   int opacity = (int)MathMax(0, MathMin(255, FillOpacity));
   ObjectSetInteger(0, name, OBJPROP_COLOR, (long)ColorToARGB(session_color, (uchar)opacity));
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void RenderSessions()
{
   int asian_start, asian_end, london_start, london_end, newyork_start, newyork_end;
   if(!ParseClock(AsianStart, asian_start) || !ParseClock(AsianEnd, asian_end) ||
      !ParseClock(LondonStart, london_start) || !ParseClock(LondonEnd, london_end) ||
      !ParseClock(NewYorkStart, newyork_start) || !ParseClock(NewYorkEnd, newyork_end))
   {
      Print("SessionHighlighter: session times must use HH:MM (24-hour) format.");
      return;
   }

   double top_price, bottom_price;
   if(!ChartGetDouble(0, CHART_PRICE_MAX, 0, top_price) ||
      !ChartGetDouble(0, CHART_PRICE_MIN, 0, bottom_price))
      return;

   DeleteSessionObjects();

   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   int days = MathMax(1, DaysToDisplay);
   for(int day_offset = 0; day_offset < days; day_offset++)
   {
      datetime day_start = today - day_offset * 24 * 60 * 60;
      if(ShowAsian)
         DrawSession("Asian", day_start, asian_start, asian_end, AsianColor, top_price, bottom_price);
      if(ShowLondon)
         DrawSession("London", day_start, london_start, london_end, LondonColor, top_price, bottom_price);
      if(ShowNewYork)
         DrawSession("NewYork", day_start, newyork_start, newyork_end, NewYorkColor, top_price, bottom_price);
   }
}

int OnInit()
{
   EventSetTimer(5);
   RenderSessions();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteSessionObjects();
}

void OnTimer()
{
   RenderSessions();
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
      RenderSessions();
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   return rates_total;
}
//+------------------------------------------------------------------+
