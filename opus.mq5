//+------------------------------------------------------------------+
//|                                                        12.mq5    |
//|                                   EA Sweep Strategy - SMC Based  |
//|                                    Copyright 2025, Sweep Trading |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Sweep Trading"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
// Trade Settings
input long     MagicNumber        = 13102025;    // Magic Number
input double   RiskPercent        = 1.0;         // Risk % per trade
input double   RR_Ratio           = 2.0;         // Risk:Reward Ratio
input int      MaxSlippagePips    = 2;           // Max Slippage (pips)
input int      OrderRetries       = 3;           // Order Retries
input int      BackupSLTPBuffer   = 50;          // Backup SL/TP Buffer (points) - safety margin for broker SL/TP

// Session Settings (GMT Time)
input int      EU_Session_Start   = 6;           // EU Session Start (GMT)
input int      EU_Session_End     = 9;           // EU Session End (GMT)
input int      US_Session_Start   = 12;          // US Session Start (GMT)
input int      US_Session_End     = 15;          // US Session End (GMT)
input int      Broker_GMT_Offset  = 2;           // Broker GMT Offset

// Strategy Settings
input bool     RequireNewBottomToSweep = false;  // Conservative Mode (wait confirmation)

// EMA Settings
input int      EMA_Fast_Period    = 21;          // EMA Fast Period
input int      EMA_Slow_Period    = 34;          // EMA Slow Period

// Visualization
input bool     ShowArrows         = true;        // Show Peak/Bottom Arrows
input bool     ShowSessionLines   = true;        // Show Session Lines

//+------------------------------------------------------------------+
//| Enums                                                             |
//+------------------------------------------------------------------+
enum ENUM_TREND {
   TREND_UP,
   TREND_DOWN,
   TREND_NONE
};

enum ENUM_STATE {
   STATE_FIND_FIRST_PEAK,
   STATE_HAS_PEAK_FIND_BOTTOM,
   STATE_HAS_BOTTOM_FIND_PEAK
};

enum ENUM_SESSION {
   SESSION_NONE,
   SESSION_EU,
   SESSION_US
};

//+------------------------------------------------------------------+
//| Structures                                                        |
//+------------------------------------------------------------------+
struct SwingPoint {
   double   price;
   datetime time;
   bool     isM30;        // true = M30, false = M5
};

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CSymbolInfo    symbolInfo;
CPositionInfo  posInfo;

// Indicator handles
int            emaFastHandle;
int            emaSlowHandle;

// Trend
ENUM_TREND     currentTrend = TREND_NONE;

// State machines
ENUM_STATE     m30State = STATE_FIND_FIRST_PEAK;
ENUM_STATE     m5State  = STATE_FIND_FIRST_PEAK;

// M30 Peaks/Bottoms
SwingPoint     m30Peaks[];
SwingPoint     m30Bottoms[];
double         m30PotentialPeakPrice = 0;
datetime       m30PotentialPeakTime  = 0;
double         m30PotentialBottomPrice = 0;
datetime       m30PotentialBottomTime  = 0;

// M5 Peaks/Bottoms
SwingPoint     m5Peaks[];
SwingPoint     m5Bottoms[];
double         m5PotentialPeakPrice = 0;
datetime       m5PotentialPeakTime  = 0;
double         m5PotentialBottomPrice = 0;
datetime       m5PotentialBottomTime  = 0;

// Session tracking
double         sessionHighPrice = 0;      // HSP - Highest Session Price
double         sessionLowPrice  = DBL_MAX; // LSP - Lowest Session Price
datetime       sessionHighTime = 0;       // Time when HSP was set
datetime       sessionLowTime = 0;        // Time when LSP was set
datetime       hcmpTime = 0;              // HCMP timestamp
double         hcmpPrice = 0;             // HCMP price
datetime       lcmbTime = 0;              // LCMB timestamp  
double         lcmbPrice = 0;             // LCMB price
int            m5PeaksCountAtLCMB = 0;    // Number of M5 peaks when LCMB was set
int            m5BottomsCountAtHCMP = 0;  // Number of M5 bottoms when HCMP was set

// Sweep list
SwingPoint     sweepList[];

// Tracking for M5 valid sweep points (to avoid duplicate logs)
int            lastLoggedM5ValidPeaks = 0;
int            lastLoggedM5ValidBottoms = 0;

// Bar tracking
datetime       lastM5BarTime  = 0;
datetime       lastM30BarTime = 0;

// Session state
ENUM_SESSION   currentSession = SESSION_NONE;
ENUM_SESSION   previousSession = SESSION_NONE;
datetime       sessionStartTime = 0;

// Position tracking
bool           hasPosition = false;

// Manual SL/TP tracking (to avoid spread issues)
double         manualStopLoss = 0;        // Actual price level for SL
double         manualTakeProfit = 0;      // Actual price level for TP
double         positionEntryPrice = 0;    // Entry price of current position
ENUM_POSITION_TYPE positionType = POSITION_TYPE_BUY;  // BUY or SELL

// Statistics tracking
int            totalWins = 0;             // Total winning trades
int            totalLosses = 0;           // Total losing trades
int            totalBuyOrders = 0;        // Total BUY orders
int            totalSellOrders = 0;       // Total SELL orders
int            currentWinStreak = 0;      // Current consecutive wins
int            currentLossStreak = 0;     // Current consecutive losses
int            maxWinStreak = 0;          // Max consecutive wins
int            maxLossStreak = 0;         // Max consecutive losses


//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit() {
   // Initialize symbol info
   if(!symbolInfo.Name(_Symbol)) {
      Print("Failed to initialize symbol info");
      return INIT_FAILED;
   }
   
   // Setup trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePips * 10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);
   
   // Create EMA indicators on M30
   emaFastHandle = iMA(_Symbol, PERIOD_M30, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_M30, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE) {
      Print("Failed to create EMA indicators");
      return INIT_FAILED;
   }
   
   // Initialize arrays
   ArrayResize(m30Peaks, 0);
   ArrayResize(m30Bottoms, 0);
   ArrayResize(m5Peaks, 0);
   ArrayResize(m5Bottoms, 0);
   ArrayResize(sweepList, 0);
   
   // Scan historical data
   ScanHistoricalM30(100);
   ScanHistoricalM5(100);
   
   // Update initial trend
   UpdateTrend();
   
   // Build initial sweep list
   BuildSweepList();
   
   // Set last bar times
   lastM5BarTime = iTime(_Symbol, PERIOD_M5, 0);
   lastM30BarTime = iTime(_Symbol, PERIOD_M30, 0);
   
   // Check current session
   currentSession = GetCurrentSession();
   if(currentSession != SESSION_NONE) {
      sessionStartTime = GetSessionStartTime(currentSession);
      InitializeSessionPrices();
   }
   
   Print("EA Sweep Strategy initialized successfully");
   PrintSweepList();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   // Release indicator handles
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   
   // Remove chart objects
   ObjectsDeleteAll(0, "SWEEP_");
   
   // Print trading statistics
   PrintStatistics();
   
   Print("EA Sweep Strategy deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick() {
   // Update symbol info
   symbolInfo.RefreshRates();
   
   // Check manual SL/TP every tick (to avoid spread issues)
   if(HasOpenPosition()) {
      CheckManualSLTP();
   }
   
   // Check for new M5 bar
   datetime currentM5Bar = iTime(_Symbol, PERIOD_M5, 0);
   if(currentM5Bar == lastM5BarTime) return;
   lastM5BarTime = currentM5Bar;
   
   // Check for new M30 bar - UPDATE M30 FIRST before session transition
   // This ensures M30 peaks/bottoms confirmed at session start are included in sweep list
   datetime currentM30Bar = iTime(_Symbol, PERIOD_M30, 0);
   bool isNewM30Bar = (currentM30Bar != lastM30BarTime);
   
   if(isNewM30Bar) {
      lastM30BarTime = currentM30Bar;
      UpdateTrend();
      UpdateM30PeaksBottoms();
      if(ShowSessionLines) DrawSessionMarkers();
   }
   
   // Check session transition AFTER M30 update
   ENUM_SESSION newSession = GetCurrentSession();
   HandleSessionTransition(newSession);
   
   // Update M5 peaks/bottoms (every M5 bar)
   bool m5Updated = UpdateM5PeaksBottoms();
   
   // Rebuild sweep list if needed
   if(isNewM30Bar || m5Updated) {
      BuildSweepList();
   }
   
   // Update position status
   hasPosition = HasOpenPosition();
   
   // Check entry conditions
   if(!hasPosition && currentTrend != TREND_NONE && currentSession != SESSION_NONE) {
      CheckSweepAndEntry();
   }
}

//+------------------------------------------------------------------+
//| Get current session based on GMT time                             |
//+------------------------------------------------------------------+
ENUM_SESSION GetCurrentSession() {
   datetime brokerTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(brokerTime, dt);
   
   int gmtHour = dt.hour - Broker_GMT_Offset;
   if(gmtHour < 0) gmtHour += 24;
   if(gmtHour >= 24) gmtHour -= 24;
   
   if(gmtHour >= EU_Session_Start && gmtHour < EU_Session_End)
      return SESSION_EU;
   if(gmtHour >= US_Session_Start && gmtHour < US_Session_End)
      return SESSION_US;
   
   return SESSION_NONE;
}

//+------------------------------------------------------------------+
//| Get session start time                                            |
//+------------------------------------------------------------------+
datetime GetSessionStartTime(ENUM_SESSION session) {
   datetime brokerTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(brokerTime, dt);
   
   int sessionStartHour = 0;
   if(session == SESSION_EU) sessionStartHour = EU_Session_Start + Broker_GMT_Offset;
   else if(session == SESSION_US) sessionStartHour = US_Session_Start + Broker_GMT_Offset;
   
   if(sessionStartHour >= 24) sessionStartHour -= 24;
   
   dt.hour = sessionStartHour;
   dt.min = 0;
   dt.sec = 0;
   
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Handle session transition                                         |
//+------------------------------------------------------------------+
void HandleSessionTransition(ENUM_SESSION newSession) {
   // Skip if no change
   if(newSession == currentSession) return;
   
   // Session ended
   if(currentSession != SESSION_NONE && newSession == SESSION_NONE) {
      Print("Session ended - clearing M5 data");
      ClearM5Data();
      BuildSweepList();
      PrintSweepList();
   }
   // New session started (from no session)
   else if(currentSession == SESSION_NONE && newSession != SESSION_NONE) {
      Print("Session started: ", EnumToString(newSession));
      sessionStartTime = GetSessionStartTime(newSession);
      ClearM5Data();  // Clear and re-initialize M5 state for new session
      // Build sweep list immediately with latest M30 peaks/bottoms
      BuildSweepList();
      PrintSweepList();
   }
   // Session changed (EU -> US or vice versa)
   else if(currentSession != newSession && newSession != SESSION_NONE && currentSession != SESSION_NONE) {
      Print("Session changed from ", EnumToString(currentSession), " to ", EnumToString(newSession));
      ClearM5Data();
      sessionStartTime = GetSessionStartTime(newSession);
      InitializeSessionPrices();
      BuildSweepList();
      PrintSweepList();
   }
   
   // Update session state
   previousSession = currentSession;
   currentSession = newSession;
}

//+------------------------------------------------------------------+
//| Initialize session prices                                         |
//+------------------------------------------------------------------+
void InitializeSessionPrices() {
   sessionHighPrice = 0;
   sessionLowPrice = DBL_MAX;
   sessionHighTime = 0;
   sessionLowTime = 0;
   hcmpTime = 0;
   hcmpPrice = 0;
   lcmbTime = 0;
   lcmbPrice = 0;
   m5PeaksCountAtLCMB = 0;
   m5BottomsCountAtHCMP = 0;
}

//+------------------------------------------------------------------+
//| Clear M5 data                                                     |
//+------------------------------------------------------------------+
void ClearM5Data() {
   ArrayResize(m5Peaks, 0);
   ArrayResize(m5Bottoms, 0);
   m5State = STATE_FIND_FIRST_PEAK;
   m5PotentialPeakPrice = 0;
   m5PotentialPeakTime = 0;
   m5PotentialBottomPrice = 0;
   m5PotentialBottomTime = 0;
   InitializeSessionPrices();
   
   // Reset tracking for M5 valid sweep points
   lastLoggedM5ValidPeaks = 0;
   lastLoggedM5ValidBottoms = 0;
   
   // Re-initialize M5 state machine with recent bars context
   // This ensures we don't incorrectly mark the first session candle as a peak/bottom
   InitializeM5StateWithContext();
}

//+------------------------------------------------------------------+
//| Initialize M5 state machine with recent bars context              |
//+------------------------------------------------------------------+
void InitializeM5StateWithContext() {
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   // Get last 20 M5 bars to find current potential peak/bottom
   int barsToScan = 20;
   if(CopyHigh(_Symbol, PERIOD_M5, 0, barsToScan, high) < barsToScan) return;
   if(CopyLow(_Symbol, PERIOD_M5, 0, barsToScan, low) < barsToScan) return;
   if(CopyClose(_Symbol, PERIOD_M5, 0, barsToScan, close) < barsToScan) return;
   
   // Find the highest high and lowest low in recent bars
   double highestHigh = 0;
   datetime highestHighTime = 0;
   double lowestLow = DBL_MAX;
   datetime lowestLowTime = 0;
   
   for(int i = 1; i < barsToScan; i++) {
      datetime barTime = iTime(_Symbol, PERIOD_M5, i);
      if(high[i] > highestHigh) {
         highestHigh = high[i];
         highestHighTime = barTime;
      }
      if(low[i] < lowestLow) {
         lowestLow = low[i];
         lowestLowTime = barTime;
      }
   }
   
   // Debug log
   Print("InitializeM5StateWithContext: highestHigh=", highestHigh, " @ ", TimeToString(highestHighTime),
         " | lowestLow=", lowestLow, " @ ", TimeToString(lowestLowTime));
   
   // Determine initial state based on which came last (highest high or lowest low)
   // KEEP potential prices from before session to ensure we track the ACTUAL highest/lowest
   // Peak/bottom will only be saved if confirmedTime >= sessionStartTime
   if(highestHighTime > lowestLowTime) {
      // Highest high is more recent - we're looking for bottom
      m5State = STATE_HAS_PEAK_FIND_BOTTOM;
      m5PotentialPeakPrice = highestHigh;
      m5PotentialPeakTime = highestHighTime;
      m5PotentialBottomPrice = lowestLow;
      m5PotentialBottomTime = lowestLowTime;
      Print("InitializeM5StateWithContext: State=STATE_HAS_PEAK_FIND_BOTTOM");
   }
   else {
      // Lowest low is more recent - we're looking for peak
      m5State = STATE_HAS_BOTTOM_FIND_PEAK;
      m5PotentialBottomPrice = lowestLow;
      m5PotentialBottomTime = lowestLowTime;
      m5PotentialPeakPrice = highestHigh;
      m5PotentialPeakTime = highestHighTime;
      Print("InitializeM5StateWithContext: State=STATE_HAS_BOTTOM_FIND_PEAK");
   }
}


//+------------------------------------------------------------------+
//| Update M30 trend                                                  |
//+------------------------------------------------------------------+
void UpdateTrend() {
   double emaFast[], emaSlow[], close[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(close, true);
   
   if(CopyBuffer(emaFastHandle, 0, 0, 3, emaFast) < 3) return;
   if(CopyBuffer(emaSlowHandle, 0, 0, 3, emaSlow) < 3) return;
   if(CopyClose(_Symbol, PERIOD_M30, 0, 3, close) < 3) return;
   
   ENUM_TREND prevTrend = currentTrend;
   
   // UPTREND: EMA21 > EMA34 and Close[1] > EMA21[1] and Close[2] > EMA21[2]
   if(emaFast[1] > emaSlow[1] && close[1] > emaFast[1] && close[2] > emaFast[2]) {
      currentTrend = TREND_UP;
   }
   // DOWNTREND: EMA21 < EMA34 and Close[1] < EMA21[1] and Close[2] < EMA21[2]
   else if(emaFast[1] < emaSlow[1] && close[1] < emaFast[1] && close[2] < emaFast[2]) {
      currentTrend = TREND_DOWN;
   }
   else {
      currentTrend = TREND_NONE;
   }
   
   if(prevTrend != currentTrend) {
      Print("Trend changed to: ", EnumToString(currentTrend));
   }
}

//+------------------------------------------------------------------+
//| Update M30 peaks and bottoms                                      |
//+------------------------------------------------------------------+
void UpdateM30PeaksBottoms() {
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   if(CopyHigh(_Symbol, PERIOD_M30, 0, 3, high) < 3) return;
   if(CopyLow(_Symbol, PERIOD_M30, 0, 3, low) < 3) return;
   if(CopyClose(_Symbol, PERIOD_M30, 0, 3, close) < 3) return;
   
   datetime barTime = iTime(_Symbol, PERIOD_M30, 1);
   
   ProcessStateMachine(m30State, high, low, close, barTime, true,
                       m30PotentialPeakPrice, m30PotentialPeakTime,
                       m30PotentialBottomPrice, m30PotentialBottomTime,
                       m30Peaks, m30Bottoms);
}

//+------------------------------------------------------------------+
//| Update M5 peaks and bottoms                                       |
//+------------------------------------------------------------------+
bool UpdateM5PeaksBottoms() {
   if(currentSession == SESSION_NONE) return false;
   
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   if(CopyHigh(_Symbol, PERIOD_M5, 0, 3, high) < 3) return false;
   if(CopyLow(_Symbol, PERIOD_M5, 0, 3, low) < 3) return false;
   if(CopyClose(_Symbol, PERIOD_M5, 0, 3, close) < 3) return false;
   
   datetime barTime = iTime(_Symbol, PERIOD_M5, 1);
   
   // Only process bars within current session
   if(barTime < sessionStartTime) return false;
   
   // Update session high/low prices
   bool hspUpdated = false;
   bool lspUpdated = false;
   
   if(high[1] > sessionHighPrice) {
      sessionHighPrice = high[1];
      sessionHighTime = barTime;
      hspUpdated = true;
   }
   if(low[1] < sessionLowPrice) {
      sessionLowPrice = low[1];
      sessionLowTime = barTime;
      lspUpdated = true;
   }
   
   // Log HSP/LSP updates based on trend
   if(currentTrend == TREND_UP && hspUpdated) {
      Print("HSP (Highest Session Price) updated: ", sessionHighPrice, " @ ", TimeToString(barTime));
   }
   if(currentTrend == TREND_DOWN && lspUpdated) {
      Print("LSP (Lowest Session Price) updated: ", sessionLowPrice, " @ ", TimeToString(barTime));
   }
   
   int prevPeakCount = ArraySize(m5Peaks);
   int prevBottomCount = ArraySize(m5Bottoms);
   
   bool lcmbOrHcmpUpdated = ProcessM5StateMachine(high, low, close, barTime);
   
   // Return true if peaks/bottoms changed OR if LCMB/HCMP was updated
   return (ArraySize(m5Peaks) != prevPeakCount || ArraySize(m5Bottoms) != prevBottomCount || lcmbOrHcmpUpdated);
}

//+------------------------------------------------------------------+
//| Process M5 state machine with HCMP/LCMB logic                     |
//+------------------------------------------------------------------+
bool ProcessM5StateMachine(double &high[], double &low[], double &close[], datetime barTime) {
   bool peakConfirmed = false;
   bool bottomConfirmed = false;
   double confirmedPeakPrice = 0;
   double confirmedBottomPrice = 0;
   datetime confirmedPeakTime = 0;
   datetime confirmedBottomTime = 0;
   bool lcmbUpdated = false;
   bool hcmpUpdated = false;
   
   switch(m5State) {
      case STATE_FIND_FIRST_PEAK:
         // Track highest high
         if(m5PotentialPeakPrice == 0 || high[1] > m5PotentialPeakPrice) {
            m5PotentialPeakPrice = high[1];
            m5PotentialPeakTime = barTime;
         }
         // Check peak confirmation: Close[1] < Low[2]
         if(close[1] < low[2] && m5PotentialPeakPrice > 0) {
            peakConfirmed = true;
            confirmedPeakPrice = m5PotentialPeakPrice;
            confirmedPeakTime = m5PotentialPeakTime;
            m5State = STATE_HAS_PEAK_FIND_BOTTOM;
            m5PotentialBottomPrice = low[1];
            m5PotentialBottomTime = barTime;
         }
         break;
         
      case STATE_HAS_PEAK_FIND_BOTTOM:
         // Can update peak if higher high before bottom confirms
         if(high[1] > m5PotentialPeakPrice) {
            m5PotentialPeakPrice = high[1];
            m5PotentialPeakTime = barTime;
         }
         // Track lowest low
         if(m5PotentialBottomPrice == 0 || low[1] < m5PotentialBottomPrice) {
            m5PotentialBottomPrice = low[1];
            m5PotentialBottomTime = barTime;
         }
         // Check bottom confirmation: Close[1] > High[2]
         if(close[1] > high[2] && m5PotentialBottomPrice > 0) {
            bottomConfirmed = true;
            confirmedBottomPrice = m5PotentialBottomPrice;
            confirmedBottomTime = m5PotentialBottomTime;
            m5State = STATE_HAS_BOTTOM_FIND_PEAK;
            m5PotentialPeakPrice = high[1];
            m5PotentialPeakTime = barTime;
         }
         break;
         
      case STATE_HAS_BOTTOM_FIND_PEAK:
         // Can update bottom if lower low before peak confirms
         if(low[1] < m5PotentialBottomPrice) {
            m5PotentialBottomPrice = low[1];
            m5PotentialBottomTime = barTime;
         }
         // Track highest high
         if(m5PotentialPeakPrice == 0 || high[1] > m5PotentialPeakPrice) {
            m5PotentialPeakPrice = high[1];
            m5PotentialPeakTime = barTime;
         }
         // Check peak confirmation: Close[1] < Low[2]
         if(close[1] < low[2] && m5PotentialPeakPrice > 0) {
            peakConfirmed = true;
            confirmedPeakPrice = m5PotentialPeakPrice;
            confirmedPeakTime = m5PotentialPeakTime;
            m5State = STATE_HAS_PEAK_FIND_BOTTOM;
            m5PotentialBottomPrice = low[1];
            m5PotentialBottomTime = barTime;
         }
         break;
   }
   
   // Process confirmed peak
   if(peakConfirmed) {
      // Only process if peak is within session (>= sessionStartTime)
      // Peaks from before session are ignored
      if(confirmedPeakTime >= sessionStartTime) {
         // Save count of M5 bottoms BEFORE adding this peak
         int bottomsCountBeforeThisPeak = ArraySize(m5Bottoms);
         
         // Adjust peak price: if HSP > confirmed peak price AND HSP occurred after last bottom
         // This ensures we only adjust when HSP is in the valid time range (between last bottom and this peak)
         datetime lastBottomTime = 0;
         if(ArraySize(m5Bottoms) > 0) {
            lastBottomTime = m5Bottoms[ArraySize(m5Bottoms) - 1].time;
         }
         // Only adjust if: HSP > peak price AND sessionHighTime is between lastBottomTime and confirmedPeakTime
         if(sessionHighPrice > confirmedPeakPrice && sessionHighPrice > 0 && 
            sessionHighTime > lastBottomTime && sessionHighTime <= confirmedPeakTime) {
            Print("M5 Peak price adjusted from ", confirmedPeakPrice, " to HSP ", sessionHighPrice);
            confirmedPeakPrice = sessionHighPrice;
         }
         
         // Add to m5Peaks array
         AddSwingPoint(m5Peaks, confirmedPeakPrice, confirmedPeakTime, false);
         
         // Log M5 peak confirmed
         Print("M5 Peak confirmed: ", confirmedPeakPrice, " @ ", TimeToString(confirmedPeakTime));
         
         // Update HCMP if this peak >= HSP (for UPTREND)
         if(confirmedPeakPrice >= sessionHighPrice) {
            hcmpPrice = confirmedPeakPrice;
            hcmpTime = confirmedPeakTime;
            // Save count of M5 bottoms that existed BEFORE this HCMP
            m5BottomsCountAtHCMP = bottomsCountBeforeThisPeak;
            hcmpUpdated = true;
            // Only log HCMP when trend is UPTREND (keep log clean when TREND_NONE)
            if(currentTrend == TREND_UP) {
               Print("HCMP updated: ", confirmedPeakPrice, " @ ", TimeToString(confirmedPeakTime));
            }
         }
         
         if(ShowArrows) DrawArrow("SWEEP_M5Peak_" + TimeToString(confirmedPeakTime), 
                                  confirmedPeakTime, confirmedPeakPrice, 234, clrRed, 1);
      }
   }
   
   // Process confirmed bottom
   if(bottomConfirmed) {
      // Only process if bottom is within session (>= sessionStartTime)
      // Bottoms from before session are ignored
      if(confirmedBottomTime >= sessionStartTime) {
         // Save count of M5 peaks BEFORE adding this bottom
         int peaksCountBeforeThisBottom = ArraySize(m5Peaks);
         
         // Adjust bottom price: if LSP < confirmed bottom price AND LSP occurred after last peak
         // This ensures we only adjust when LSP is in the valid time range (between last peak and this bottom)
         datetime lastPeakTime = 0;
         if(ArraySize(m5Peaks) > 0) {
            lastPeakTime = m5Peaks[ArraySize(m5Peaks) - 1].time;
         }
         // Only adjust if: LSP < bottom price AND sessionLowTime is between lastPeakTime and confirmedBottomTime
         if(sessionLowPrice < confirmedBottomPrice && sessionLowPrice < DBL_MAX &&
            sessionLowTime > lastPeakTime && sessionLowTime <= confirmedBottomTime) {
            Print("M5 Bottom price adjusted from ", confirmedBottomPrice, " to LSP ", sessionLowPrice);
            confirmedBottomPrice = sessionLowPrice;
         }
         
         // Add to m5Bottoms array
         AddSwingPoint(m5Bottoms, confirmedBottomPrice, confirmedBottomTime, false);
         
         // Log M5 bottom confirmed
         Print("M5 Bottom confirmed: ", confirmedBottomPrice, " @ ", TimeToString(confirmedBottomTime));
         
         // Update LCMB if this bottom <= LSP (for DOWNTREND)
         if(confirmedBottomPrice <= sessionLowPrice) {
            lcmbPrice = confirmedBottomPrice;
            lcmbTime = confirmedBottomTime;
            // Save count of M5 peaks that existed BEFORE this LCMB
            m5PeaksCountAtLCMB = peaksCountBeforeThisBottom;
            lcmbUpdated = true;
            // Only log LCMB when trend is DOWNTREND (keep log clean when TREND_NONE)
            if(currentTrend == TREND_DOWN) {
               Print("LCMB updated: ", confirmedBottomPrice, " @ ", TimeToString(confirmedBottomTime));
            }
         }
         
         if(ShowArrows) DrawArrow("SWEEP_M5Bottom_" + TimeToString(confirmedBottomTime),
                                  confirmedBottomTime, confirmedBottomPrice, 233, clrLime, 1);
      }
   }
   
   // Return true if LCMB or HCMP was updated (to trigger sweep list rebuild)
   return (lcmbUpdated || hcmpUpdated);
}

//+------------------------------------------------------------------+
//| Process state machine for M30                                     |
//+------------------------------------------------------------------+
void ProcessStateMachine(ENUM_STATE &state, double &high[], double &low[], double &close[],
                         datetime barTime, bool isM30,
                         double &potentialPeakPrice, datetime &potentialPeakTime,
                         double &potentialBottomPrice, datetime &potentialBottomTime,
                         SwingPoint &peaks[], SwingPoint &bottoms[]) {
   
   switch(state) {
      case STATE_FIND_FIRST_PEAK:
         if(potentialPeakPrice == 0 || high[1] > potentialPeakPrice) {
            potentialPeakPrice = high[1];
            potentialPeakTime = barTime;
         }
         if(close[1] < low[2] && potentialPeakPrice > 0) {
            AddSwingPoint(peaks, potentialPeakPrice, potentialPeakTime, isM30);
            if(ShowArrows) DrawArrow("SWEEP_M30Peak_" + TimeToString(potentialPeakTime),
                                     potentialPeakTime, potentialPeakPrice, 234, clrRed, 3);
            Print("M30 Peak confirmed: ", potentialPeakPrice, " @ ", TimeToString(potentialPeakTime));
            state = STATE_HAS_PEAK_FIND_BOTTOM;
            potentialBottomPrice = low[1];
            potentialBottomTime = barTime;
         }
         break;
         
      case STATE_HAS_PEAK_FIND_BOTTOM:
         if(high[1] > potentialPeakPrice) {
            potentialPeakPrice = high[1];
            potentialPeakTime = barTime;
         }
         if(potentialBottomPrice == 0 || low[1] < potentialBottomPrice) {
            potentialBottomPrice = low[1];
            potentialBottomTime = barTime;
         }
         if(close[1] > high[2] && potentialBottomPrice > 0) {
            AddSwingPoint(bottoms, potentialBottomPrice, potentialBottomTime, isM30);
            if(ShowArrows) DrawArrow("SWEEP_M30Bottom_" + TimeToString(potentialBottomTime),
                                     potentialBottomTime, potentialBottomPrice, 233, clrLime, 3);
            Print("M30 Bottom confirmed: ", potentialBottomPrice, " @ ", TimeToString(potentialBottomTime));
            state = STATE_HAS_BOTTOM_FIND_PEAK;
            potentialPeakPrice = high[1];
            potentialPeakTime = barTime;
         }
         break;
         
      case STATE_HAS_BOTTOM_FIND_PEAK:
         if(low[1] < potentialBottomPrice) {
            potentialBottomPrice = low[1];
            potentialBottomTime = barTime;
         }
         if(potentialPeakPrice == 0 || high[1] > potentialPeakPrice) {
            potentialPeakPrice = high[1];
            potentialPeakTime = barTime;
         }
         if(close[1] < low[2] && potentialPeakPrice > 0) {
            AddSwingPoint(peaks, potentialPeakPrice, potentialPeakTime, isM30);
            if(ShowArrows) DrawArrow("SWEEP_M30Peak_" + TimeToString(potentialPeakTime),
                                     potentialPeakTime, potentialPeakPrice, 234, clrRed, 3);
            Print("M30 Peak confirmed: ", potentialPeakPrice, " @ ", TimeToString(potentialPeakTime));
            state = STATE_HAS_PEAK_FIND_BOTTOM;
            potentialBottomPrice = low[1];
            potentialBottomTime = barTime;
         }
         break;
   }
}


//+------------------------------------------------------------------+
//| Add swing point to array                                          |
//+------------------------------------------------------------------+
void AddSwingPoint(SwingPoint &arr[], double price, datetime time, bool isM30) {
   int size = ArraySize(arr);
   ArrayResize(arr, size + 1);
   arr[size].price = price;
   arr[size].time = time;
   arr[size].isM30 = isM30;
}

//+------------------------------------------------------------------+
//| Build sweep list based on current trend                           |
//+------------------------------------------------------------------+
void BuildSweepList() {
   ArrayResize(sweepList, 0);
   
   if(currentTrend == TREND_UP) {
      // Merge M30 bottoms + valid M5 bottoms
      // M5 bottoms valid only if they were confirmed BEFORE HCMP was set
      
      // Add all M30 bottoms
      for(int i = 0; i < ArraySize(m30Bottoms); i++) {
         AddSwingPoint(sweepList, m30Bottoms[i].price, m30Bottoms[i].time, true);
      }
      
      // Add valid M5 bottoms (confirmed before HCMP and within session)
      // Only bottoms with index < m5BottomsCountAtHCMP are valid (they existed before HCMP was set)
      // Bottom must be at or after session start (>= to include first candle)
      // Bottom confirmation time must be BEFORE HCMP time
      int validM5BottomCount = 0;
      if(hcmpTime > 0 && sessionStartTime > 0 && m5BottomsCountAtHCMP > 0) {
         for(int i = 0; i < m5BottomsCountAtHCMP && i < ArraySize(m5Bottoms); i++) {
            // Must be at or after session start (>= to include first candle)
            // AND must be BEFORE HCMP time (bottom confirmed before HCMP)
            if(m5Bottoms[i].time >= sessionStartTime && m5Bottoms[i].time < hcmpTime) {
               AddSwingPoint(sweepList, m5Bottoms[i].price, m5Bottoms[i].time, false);
               validM5BottomCount++;
            }
         }
      }
      
      // Log only new M5 valid bottoms (avoid duplicate logs)
      if(validM5BottomCount > lastLoggedM5ValidBottoms) {
         // Log only the new ones
         int newCount = 0;
         if(hcmpTime > 0 && sessionStartTime > 0 && m5BottomsCountAtHCMP > 0) {
            for(int i = 0; i < m5BottomsCountAtHCMP && i < ArraySize(m5Bottoms); i++) {
               // Same condition as above
               if(m5Bottoms[i].time >= sessionStartTime && m5Bottoms[i].time < hcmpTime) {
                  newCount++;
                  if(newCount > lastLoggedM5ValidBottoms) {
                     Print("M5-Bottom-need-sweep-in-session: ", m5Bottoms[i].price, " @ ", TimeToString(m5Bottoms[i].time));
                  }
               }
            }
         }
         lastLoggedM5ValidBottoms = validM5BottomCount;
         
         // Sort by time (newest first)
         SortSwingPointsByTime(sweepList);
         
         // Filter: keep only descending bottoms
         FilterDescendingBottoms();
         
         // Print sweep list when new M5 valid found
         PrintSweepList();
         return;
      }
      
      // Sort by time (newest first)
      SortSwingPointsByTime(sweepList);
      
      // Filter: keep only descending bottoms
      FilterDescendingBottoms();
   }
   else if(currentTrend == TREND_DOWN) {
      // Merge M30 peaks + valid M5 peaks
      // M5 peaks valid only if they were confirmed BEFORE LCMB was set
      
      // Add all M30 peaks
      for(int i = 0; i < ArraySize(m30Peaks); i++) {
         AddSwingPoint(sweepList, m30Peaks[i].price, m30Peaks[i].time, true);
      }
      
      // Add valid M5 peaks (confirmed before LCMB and within session)
      // Only peaks with index < m5PeaksCountAtLCMB are valid (they existed before LCMB was set)
      // Peak must be at or after session start (>= to include first candle)
      // Peak confirmation time must be BEFORE LCMB time
      int validM5PeakCount = 0;
      if(lcmbTime > 0 && sessionStartTime > 0 && m5PeaksCountAtLCMB > 0) {
         for(int i = 0; i < m5PeaksCountAtLCMB && i < ArraySize(m5Peaks); i++) {
            // Must be at or after session start (>= to include first candle)
            // AND must be BEFORE LCMB time (peak confirmed before LCMB)
            if(m5Peaks[i].time >= sessionStartTime && m5Peaks[i].time < lcmbTime) {
               AddSwingPoint(sweepList, m5Peaks[i].price, m5Peaks[i].time, false);
               validM5PeakCount++;
            }
         }
      }
      
      // Log only new M5 valid peaks (avoid duplicate logs)
      if(validM5PeakCount > lastLoggedM5ValidPeaks) {
         // Log only the new ones
         int newCount = 0;
         if(lcmbTime > 0 && sessionStartTime > 0 && m5PeaksCountAtLCMB > 0) {
            for(int i = 0; i < m5PeaksCountAtLCMB && i < ArraySize(m5Peaks); i++) {
               // Same condition as above
               if(m5Peaks[i].time >= sessionStartTime && m5Peaks[i].time < lcmbTime) {
                  newCount++;
                  if(newCount > lastLoggedM5ValidPeaks) {
                     Print("M5-Peak-need-sweep-in-session: ", m5Peaks[i].price, " @ ", TimeToString(m5Peaks[i].time));
                  }
               }
            }
         }
         lastLoggedM5ValidPeaks = validM5PeakCount;
         
         // Sort by time (newest first)
         SortSwingPointsByTime(sweepList);
         
         // Filter: keep only ascending peaks
         FilterAscendingPeaks();
         
         // Print sweep list when new M5 valid found
         PrintSweepList();
         return;
      }
      
      // Sort by time (newest first)
      SortSwingPointsByTime(sweepList);
      
      // Filter: keep only ascending peaks
      FilterAscendingPeaks();
   }
}

//+------------------------------------------------------------------+
//| Sort swing points by time (newest first)                          |
//+------------------------------------------------------------------+
void SortSwingPointsByTime(SwingPoint &arr[]) {
   int size = ArraySize(arr);
   for(int i = 0; i < size - 1; i++) {
      for(int j = i + 1; j < size; j++) {
         if(arr[j].time > arr[i].time) {
            SwingPoint temp = arr[i];
            arr[i] = arr[j];
            arr[j] = temp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Filter to keep only descending bottoms (for UPTREND)              |
//+------------------------------------------------------------------+
void FilterDescendingBottoms() {
   if(ArraySize(sweepList) <= 1) return;
   
   SwingPoint filtered[];
   ArrayResize(filtered, 0);
   
   // First item always kept
   AddSwingPoint(filtered, sweepList[0].price, sweepList[0].time, sweepList[0].isM30);
   
   // Keep only if lower than all previous
   for(int i = 1; i < ArraySize(sweepList); i++) {
      bool isLower = true;
      for(int j = 0; j < ArraySize(filtered); j++) {
         if(sweepList[i].price >= filtered[j].price) {
            isLower = false;
            break;
         }
      }
      if(isLower) {
         AddSwingPoint(filtered, sweepList[i].price, sweepList[i].time, sweepList[i].isM30);
      }
   }
   
   ArrayResize(sweepList, ArraySize(filtered));
   for(int i = 0; i < ArraySize(filtered); i++) {
      sweepList[i] = filtered[i];
   }
}

//+------------------------------------------------------------------+
//| Filter to keep only ascending peaks (for DOWNTREND)               |
//+------------------------------------------------------------------+
void FilterAscendingPeaks() {
   if(ArraySize(sweepList) <= 1) return;
   
   SwingPoint filtered[];
   ArrayResize(filtered, 0);
   
   // First item always kept
   AddSwingPoint(filtered, sweepList[0].price, sweepList[0].time, sweepList[0].isM30);
   
   // Keep only if higher than all previous
   for(int i = 1; i < ArraySize(sweepList); i++) {
      bool isHigher = true;
      for(int j = 0; j < ArraySize(filtered); j++) {
         if(sweepList[i].price <= filtered[j].price) {
            isHigher = false;
            break;
         }
      }
      if(isHigher) {
         AddSwingPoint(filtered, sweepList[i].price, sweepList[i].time, sweepList[i].isM30);
      }
   }
   
   ArrayResize(sweepList, ArraySize(filtered));
   for(int i = 0; i < ArraySize(filtered); i++) {
      sweepList[i] = filtered[i];
   }
}

//+------------------------------------------------------------------+
//| Check sweep and entry                                             |
//+------------------------------------------------------------------+
void CheckSweepAndEntry() {
   if(ArraySize(sweepList) == 0) return;
   
   if(currentTrend == TREND_UP && ArraySize(m5Bottoms) > 0) {
      // Must have HCMP first before checking sweep
      if(hcmpTime == 0) return;
      
      // Get last M5 bottom - must be AFTER HCMP and within session
      SwingPoint lastBottom;
      bool foundValidBottom = false;
      
      for(int i = ArraySize(m5Bottoms) - 1; i >= 0; i--) {
         // Bottom must be after HCMP and after session start
         if(m5Bottoms[i].time > hcmpTime && m5Bottoms[i].time > sessionStartTime) {
            lastBottom = m5Bottoms[i];
            foundValidBottom = true;
            break;
         }
      }
      
      if(!foundValidBottom) return;
      
      // Check against sweep list
      for(int i = 0; i < ArraySize(sweepList); i++) {
         if(lastBottom.price < sweepList[i].price) {
            Print("SWEEP DETECTED! Last M5 bottom ", lastBottom.price, 
                  " swept level ", sweepList[i].price);
            EntryBuy(lastBottom.price);
            break;
         }
      }
   }
   else if(currentTrend == TREND_DOWN && ArraySize(m5Peaks) > 0) {
      // Must have LCMB first before checking sweep
      if(lcmbTime == 0) return;
      
      // Get last M5 peak - must be AFTER LCMB and within session
      SwingPoint lastPeak;
      bool foundValidPeak = false;
      
      for(int i = ArraySize(m5Peaks) - 1; i >= 0; i--) {
         // Peak must be after LCMB and after session start
         if(m5Peaks[i].time > lcmbTime && m5Peaks[i].time > sessionStartTime) {
            lastPeak = m5Peaks[i];
            foundValidPeak = true;
            break;
         }
      }
      
      if(!foundValidPeak) return;
      
      // Check against sweep list
      for(int i = 0; i < ArraySize(sweepList); i++) {
         if(lastPeak.price > sweepList[i].price) {
            Print("SWEEP DETECTED! Last M5 peak ", lastPeak.price,
                  " swept level ", sweepList[i].price);
            EntrySell(lastPeak.price);
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Entry BUY                                                         |
//+------------------------------------------------------------------+
void EntryBuy(double sweptLevel) {
   symbolInfo.RefreshRates();
   
   double entryPrice = symbolInfo.Ask();
   double stopLoss = sweptLevel;
   double riskPips = (entryPrice - stopLoss) / symbolInfo.Point();
   
   if(riskPips <= 0) {
      Print("Invalid risk calculation for BUY");
      return;
   }
   
   double takeProfit = entryPrice + (entryPrice - stopLoss) * RR_Ratio;
   double lotSize = CalculateLotSize(entryPrice, stopLoss);
   
   if(lotSize <= 0) {
      Print("Invalid lot size calculated");
      return;
   }
   
   // Normalize prices
   stopLoss = NormalizeDouble(stopLoss, symbolInfo.Digits());
   takeProfit = NormalizeDouble(takeProfit, symbolInfo.Digits());
   
   Print("Attempting BUY: Entry=", entryPrice, " SL=", stopLoss, " TP=", takeProfit, " Lot=", lotSize);
   
   // Calculate backup SL/TP for broker (with buffer for safety)
   double backupSL = NormalizeDouble(stopLoss - BackupSLTPBuffer * symbolInfo.Point(), symbolInfo.Digits());
   double backupTP = NormalizeDouble(takeProfit + BackupSLTPBuffer * symbolInfo.Point(), symbolInfo.Digits());
   
   for(int i = 0; i < OrderRetries; i++) {
      // Open with backup broker SL/TP (wider than manual SL/TP for safety)
      if(trade.Buy(lotSize, _Symbol, entryPrice, backupSL, backupTP, "Sweep Buy")) {
         Print("BUY order placed successfully (Manual SL/TP with Backup)");
         Print("Manual SL=", stopLoss, " | Backup SL=", backupSL);
         Print("Manual TP=", takeProfit, " | Backup TP=", backupTP);
         // Store manual SL/TP levels
         manualStopLoss = stopLoss;
         manualTakeProfit = takeProfit;
         positionEntryPrice = entryPrice;
         positionType = POSITION_TYPE_BUY;
         // Update statistics
         totalBuyOrders++;
         return;
      }
      Print("BUY order failed, retry ", i + 1, " Error: ", GetLastError());
      Sleep(100);
   }
}

//+------------------------------------------------------------------+
//| Entry SELL                                                        |
//+------------------------------------------------------------------+
void EntrySell(double sweptLevel) {
   symbolInfo.RefreshRates();
   
   double entryPrice = symbolInfo.Bid();
   double stopLoss = sweptLevel;
   double riskPips = (stopLoss - entryPrice) / symbolInfo.Point();
   
   if(riskPips <= 0) {
      Print("Invalid risk calculation for SELL");
      return;
   }
   
   double takeProfit = entryPrice - (stopLoss - entryPrice) * RR_Ratio;
   double lotSize = CalculateLotSize(entryPrice, stopLoss);
   
   if(lotSize <= 0) {
      Print("Invalid lot size calculated");
      return;
   }
   
   // Normalize prices
   stopLoss = NormalizeDouble(stopLoss, symbolInfo.Digits());
   takeProfit = NormalizeDouble(takeProfit, symbolInfo.Digits());
   
   Print("Attempting SELL: Entry=", entryPrice, " SL=", stopLoss, " TP=", takeProfit, " Lot=", lotSize);
   
   // Calculate backup SL/TP for broker (with buffer for safety)
   double backupSL = NormalizeDouble(stopLoss + BackupSLTPBuffer * symbolInfo.Point(), symbolInfo.Digits());
   double backupTP = NormalizeDouble(takeProfit - BackupSLTPBuffer * symbolInfo.Point(), symbolInfo.Digits());
   
   for(int i = 0; i < OrderRetries; i++) {
      // Open with backup broker SL/TP (wider than manual SL/TP for safety)
      if(trade.Sell(lotSize, _Symbol, entryPrice, backupSL, backupTP, "Sweep Sell")) {
         Print("SELL order placed successfully (Manual SL/TP with Backup)");
         Print("Manual SL=", stopLoss, " | Backup SL=", backupSL);
         Print("Manual TP=", takeProfit, " | Backup TP=", backupTP);
         // Store manual SL/TP levels
         manualStopLoss = stopLoss;
         manualTakeProfit = takeProfit;
         positionEntryPrice = entryPrice;
         positionType = POSITION_TYPE_SELL;
         // Update statistics
         totalSellOrders++;
         return;
      }
      Print("SELL order failed, retry ", i + 1, " Error: ", GetLastError());
      Sleep(100);
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double stopLoss) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   
   double riskPoints = MathAbs(entryPrice - stopLoss) / symbolInfo.Point();
   if(riskPoints == 0) return 0;
   
   double tickValue = symbolInfo.TickValue();
   double tickSize = symbolInfo.TickSize();
   double pointValue = tickValue * (symbolInfo.Point() / tickSize);
   
   double lotSize = riskAmount / (riskPoints * pointValue);
   
   // Normalize lot size
   double lotStep = symbolInfo.LotsStep();
   double minLot = symbolInfo.LotsMin();
   double maxLot = symbolInfo.LotsMax();
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Check if has open position                                        |
//+------------------------------------------------------------------+
bool HasOpenPosition() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber) {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check manual SL/TP based on actual candle price (avoid spread)    |
//+------------------------------------------------------------------+
void CheckManualSLTP() {
   if(manualStopLoss == 0 && manualTakeProfit == 0) return;
   
   // Get current candle high/low (use index 0 for current forming candle)
   double currentHigh = iHigh(_Symbol, PERIOD_M5, 0);
   double currentLow = iLow(_Symbol, PERIOD_M5, 0);
   double currentBid = symbolInfo.Bid();
   double currentAsk = symbolInfo.Ask();
   
   bool shouldCloseSL = false;
   bool shouldCloseTP = false;
   
   if(positionType == POSITION_TYPE_BUY) {
      // BUY position: SL when Low touches SL level, TP when High touches TP level
      if(manualStopLoss > 0 && currentLow <= manualStopLoss) {
         shouldCloseSL = true;
         Print("Manual SL triggered for BUY: Low=", currentLow, " <= SL=", manualStopLoss);
      }
      if(manualTakeProfit > 0 && currentHigh >= manualTakeProfit) {
         shouldCloseTP = true;
         Print("Manual TP triggered for BUY: High=", currentHigh, " >= TP=", manualTakeProfit);
      }
   }
   else if(positionType == POSITION_TYPE_SELL) {
      // SELL position: SL when High touches SL level, TP when Low touches TP level
      if(manualStopLoss > 0 && currentHigh >= manualStopLoss) {
         shouldCloseSL = true;
         Print("Manual SL triggered for SELL: High=", currentHigh, " >= SL=", manualStopLoss);
      }
      if(manualTakeProfit > 0 && currentLow <= manualTakeProfit) {
         shouldCloseTP = true;
         Print("Manual TP triggered for SELL: Low=", currentLow, " <= TP=", manualTakeProfit);
      }
   }
   
   // Close position if SL or TP triggered
   if(shouldCloseSL || shouldCloseTP) {
      CloseAllPositions(shouldCloseTP ? "TP" : "SL");
   }
}

//+------------------------------------------------------------------+
//| Close all positions for this EA                                   |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber) {
            ulong ticket = posInfo.Ticket();
            double profit = posInfo.Profit();
            double volume = posInfo.Volume();
            ENUM_POSITION_TYPE posType = posInfo.PositionType();
            
            // Set comment based on reason
            string closeComment = "";
            if(reason == "SL") {
               closeComment = "-----------STOPLOSS";
            }
            else if(reason == "TP") {
               closeComment = "-----------TP";
            }
            else {
               closeComment = reason;
            }
            
            // Close position using OrderSend with comment
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            
            request.action = TRADE_ACTION_DEAL;
            request.symbol = _Symbol;
            request.volume = volume;
            request.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            request.price = (posType == POSITION_TYPE_BUY) ? symbolInfo.Bid() : symbolInfo.Ask();
            request.position = ticket;
            request.deviation = MaxSlippagePips * 10;
            request.magic = MagicNumber;
            request.comment = closeComment;
            request.type_filling = ORDER_FILLING_IOC;
            
            if(OrderSend(request, result)) {
               if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL) {
                  Print(closeComment, " | Position closed. Ticket=", ticket, " Profit=", profit);
                  
                  // Update statistics
                  UpdateStatistics(reason, posType);
                  
                  // Reset manual SL/TP
                  manualStopLoss = 0;
                  manualTakeProfit = 0;
                  positionEntryPrice = 0;
               }
               else {
                  Print("Close position failed. Retcode=", result.retcode);
               }
            }
            else {
               Print("Failed to close position. Error: ", GetLastError());
            }
         }
      }
   }
}


//+------------------------------------------------------------------+
//| Scan historical M30 data                                          |
//+------------------------------------------------------------------+
void ScanHistoricalM30(int bars) {
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   if(CopyHigh(_Symbol, PERIOD_M30, 0, bars, high) < bars) return;
   if(CopyLow(_Symbol, PERIOD_M30, 0, bars, low) < bars) return;
   if(CopyClose(_Symbol, PERIOD_M30, 0, bars, close) < bars) return;
   
   // Reset state
   m30State = STATE_FIND_FIRST_PEAK;
   m30PotentialPeakPrice = 0;
   m30PotentialBottomPrice = 0;
   
   // Process from oldest to newest
   for(int i = bars - 3; i >= 1; i--) {
      datetime barTime = iTime(_Symbol, PERIOD_M30, i);
      
      double h[3] = {high[i-1], high[i], high[i+1]};
      double l[3] = {low[i-1], low[i], low[i+1]};
      double c[3] = {close[i-1], close[i], close[i+1]};
      
      ProcessStateMachine(m30State, h, l, c, barTime, true,
                          m30PotentialPeakPrice, m30PotentialPeakTime,
                          m30PotentialBottomPrice, m30PotentialBottomTime,
                          m30Peaks, m30Bottoms);
   }
   
   Print("Historical M30 scan complete. Peaks: ", ArraySize(m30Peaks), " Bottoms: ", ArraySize(m30Bottoms));
}

//+------------------------------------------------------------------+
//| Scan historical M5 data                                           |
//+------------------------------------------------------------------+
void ScanHistoricalM5(int bars) {
   // Only scan if currently in session
   if(GetCurrentSession() == SESSION_NONE) return;
   
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   if(CopyHigh(_Symbol, PERIOD_M5, 0, bars, high) < bars) return;
   if(CopyLow(_Symbol, PERIOD_M5, 0, bars, low) < bars) return;
   if(CopyClose(_Symbol, PERIOD_M5, 0, bars, close) < bars) return;
   
   // Find session start
   datetime sessStart = GetSessionStartTime(currentSession);
   
   // Reset state
   m5State = STATE_FIND_FIRST_PEAK;
   m5PotentialPeakPrice = 0;
   m5PotentialBottomPrice = 0;
   sessionHighPrice = 0;
   sessionLowPrice = DBL_MAX;
   
   // Process from oldest to newest, only bars within session
   for(int i = bars - 3; i >= 1; i--) {
      datetime barTime = iTime(_Symbol, PERIOD_M5, i);
      if(barTime < sessStart) continue;
      
      // Update session high/low
      if(high[i] > sessionHighPrice) sessionHighPrice = high[i];
      if(low[i] < sessionLowPrice) sessionLowPrice = low[i];
      
      double h[3] = {high[i-1], high[i], high[i+1]};
      double l[3] = {low[i-1], low[i], low[i+1]};
      double c[3] = {close[i-1], close[i], close[i+1]};
      
      ProcessM5HistoricalBar(h, l, c, barTime);
   }
   
   Print("Historical M5 scan complete. Peaks: ", ArraySize(m5Peaks), " Bottoms: ", ArraySize(m5Bottoms));
}

//+------------------------------------------------------------------+
//| Process M5 historical bar                                         |
//+------------------------------------------------------------------+
void ProcessM5HistoricalBar(double &high[], double &low[], double &close[], datetime barTime) {
   bool peakConfirmed = false;
   bool bottomConfirmed = false;
   double confirmedPeakPrice = 0;
   double confirmedBottomPrice = 0;
   datetime confirmedPeakTime = 0;
   datetime confirmedBottomTime = 0;
   
   switch(m5State) {
      case STATE_FIND_FIRST_PEAK:
         if(m5PotentialPeakPrice == 0 || high[1] > m5PotentialPeakPrice) {
            m5PotentialPeakPrice = high[1];
            m5PotentialPeakTime = barTime;
         }
         if(close[1] < low[2] && m5PotentialPeakPrice > 0) {
            peakConfirmed = true;
            confirmedPeakPrice = m5PotentialPeakPrice;
            confirmedPeakTime = m5PotentialPeakTime;
            m5State = STATE_HAS_PEAK_FIND_BOTTOM;
            m5PotentialBottomPrice = low[1];
            m5PotentialBottomTime = barTime;
         }
         break;
         
      case STATE_HAS_PEAK_FIND_BOTTOM:
         if(high[1] > m5PotentialPeakPrice) {
            m5PotentialPeakPrice = high[1];
            m5PotentialPeakTime = barTime;
         }
         if(m5PotentialBottomPrice == 0 || low[1] < m5PotentialBottomPrice) {
            m5PotentialBottomPrice = low[1];
            m5PotentialBottomTime = barTime;
         }
         if(close[1] > high[2] && m5PotentialBottomPrice > 0) {
            bottomConfirmed = true;
            confirmedBottomPrice = m5PotentialBottomPrice;
            confirmedBottomTime = m5PotentialBottomTime;
            m5State = STATE_HAS_BOTTOM_FIND_PEAK;
            m5PotentialPeakPrice = high[1];
            m5PotentialPeakTime = barTime;
         }
         break;
         
      case STATE_HAS_BOTTOM_FIND_PEAK:
         if(low[1] < m5PotentialBottomPrice) {
            m5PotentialBottomPrice = low[1];
            m5PotentialBottomTime = barTime;
         }
         if(m5PotentialPeakPrice == 0 || high[1] > m5PotentialPeakPrice) {
            m5PotentialPeakPrice = high[1];
            m5PotentialPeakTime = barTime;
         }
         if(close[1] < low[2] && m5PotentialPeakPrice > 0) {
            peakConfirmed = true;
            confirmedPeakPrice = m5PotentialPeakPrice;
            confirmedPeakTime = m5PotentialPeakTime;
            m5State = STATE_HAS_PEAK_FIND_BOTTOM;
            m5PotentialBottomPrice = low[1];
            m5PotentialBottomTime = barTime;
         }
         break;
   }
   
   if(peakConfirmed) {
      if(confirmedPeakPrice >= sessionHighPrice) {
         hcmpPrice = confirmedPeakPrice;
         hcmpTime = confirmedPeakTime;
      }
      AddSwingPoint(m5Peaks, confirmedPeakPrice, confirmedPeakTime, false);
   }
   
   if(bottomConfirmed) {
      if(confirmedBottomPrice <= sessionLowPrice) {
         lcmbPrice = confirmedBottomPrice;
         lcmbTime = confirmedBottomTime;
      }
      AddSwingPoint(m5Bottoms, confirmedBottomPrice, confirmedBottomTime, false);
   }
}

//+------------------------------------------------------------------+
//| Draw arrow on chart                                               |
//+------------------------------------------------------------------+
void DrawArrow(string name, datetime time, double price, int code, color clr, int size) {
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   
   ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, size);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, code == 233 ? ANCHOR_TOP : ANCHOR_BOTTOM);
}

//+------------------------------------------------------------------+
//| Draw session markers                                              |
//+------------------------------------------------------------------+
void DrawSessionMarkers() {
   datetime brokerTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(brokerTime, dt);
   
   // EU Session lines
   int euStartHour = EU_Session_Start + Broker_GMT_Offset;
   int euEndHour = EU_Session_End + Broker_GMT_Offset;
   if(euStartHour >= 24) euStartHour -= 24;
   if(euEndHour >= 24) euEndHour -= 24;
   
   dt.hour = euStartHour;
   dt.min = 0;
   dt.sec = 0;
   datetime euStart = StructToTime(dt);
   
   dt.hour = euEndHour;
   datetime euEnd = StructToTime(dt);
   
   DrawVLine("SWEEP_EU_Start_" + TimeToString(euStart, TIME_DATE), euStart, clrBlue);
   DrawVLine("SWEEP_EU_End_" + TimeToString(euEnd, TIME_DATE), euEnd, clrBlue);
   
   // US Session lines
   int usStartHour = US_Session_Start + Broker_GMT_Offset;
   int usEndHour = US_Session_End + Broker_GMT_Offset;
   if(usStartHour >= 24) usStartHour -= 24;
   if(usEndHour >= 24) usEndHour -= 24;
   
   dt.hour = usStartHour;
   datetime usStart = StructToTime(dt);
   
   dt.hour = usEndHour;
   datetime usEnd = StructToTime(dt);
   
   DrawVLine("SWEEP_US_Start_" + TimeToString(usStart, TIME_DATE), usStart, clrRed);
   DrawVLine("SWEEP_US_End_" + TimeToString(usEnd, TIME_DATE), usEnd, clrRed);
}

//+------------------------------------------------------------------+
//| Draw vertical line                                                |
//+------------------------------------------------------------------+
void DrawVLine(string name, datetime time, color clr) {
   if(ObjectFind(0, name) >= 0) return;
   
   ObjectCreate(0, name, OBJ_VLINE, 0, time, 0);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| Print sweep list                                                  |
//+------------------------------------------------------------------+
void PrintSweepList() {
   Print("=== SWEEP LIST (", EnumToString(currentTrend), ") ===");
   for(int i = 0; i < ArraySize(sweepList); i++) {
      Print("[", i, "] Price: ", sweepList[i].price, 
            " Time: ", TimeToString(sweepList[i].time),
            " TF: ", (sweepList[i].isM30 ? "M30" : "M5"));
   }
   Print("=== END SWEEP LIST ===");
}

//+------------------------------------------------------------------+
//| Update statistics after closing position                          |
//+------------------------------------------------------------------+
void UpdateStatistics(string reason, ENUM_POSITION_TYPE posType) {
   if(reason == "TP") {
      // Win
      totalWins++;
      currentWinStreak++;
      currentLossStreak = 0;
      if(currentWinStreak > maxWinStreak) {
         maxWinStreak = currentWinStreak;
      }
   }
   else if(reason == "SL") {
      // Loss
      totalLosses++;
      currentLossStreak++;
      currentWinStreak = 0;
      if(currentLossStreak > maxLossStreak) {
         maxLossStreak = currentLossStreak;
      }
   }
}

//+------------------------------------------------------------------+
//| Print trading statistics                                          |
//+------------------------------------------------------------------+
void PrintStatistics() {
   int totalTrades = totalWins + totalLosses;
   double winRate = (totalTrades > 0) ? (double)totalWins / totalTrades * 100.0 : 0.0;
   
   Print("╔══════════════════════════════════════════════════════════════╗");
   Print("║                    TRADING STATISTICS                        ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║  Total Wins:              ", totalWins);
   Print("║  Total Losses:            ", totalLosses);
   Print("║  Win Rate:                ", DoubleToString(winRate, 2), "%");
   Print("║  Max Consecutive Wins:    ", maxWinStreak);
   Print("║  Max Consecutive Losses:  ", maxLossStreak);
   Print("║  Total BUY Orders:        ", totalBuyOrders);
   Print("║  Total SELL Orders:       ", totalSellOrders);
   Print("║  Total Orders:            ", totalBuyOrders + totalSellOrders);
   Print("╚══════════════════════════════════════════════════════════════╝");
}
//+------------------------------------------------------------------+
