//+------------------------------------------------------------------+
//|                                          TradeAccountMonitor.mq4 |
//|                                Copyright 2020, Maxim A.Kuznetsov |
//|                                          https://www.luxtrade.tk |
//+------------------------------------------------------------------+
#property copyright "Copyright 2020, Maxim A.Kuznetsov"
#property link      "https://www.luxtrade.tk"
#property version   "1.00"
#property strict
#property indicator_chart_window

//--- input parameters
sinput string   Server="localhost"; 
sinput string   CACert="cacert.pem";  
sinput bool     AuthCert=false;     
sinput string   Login="";           
sinput string   Password="";        
sinput string   BasePath="TradeAccountMonitor";

/***
   Информация записывается в следующем виде
   Базовый путь:

   {BasePath}/{Company}/{Account}/

   hb - heat beat - периодическое оповещение жив-ли, записывается GMT секунд

   started   - GMT время загрузки индикатора
   connected - признак соединения с торговым сервером true/false
   tradeable - признак разрешения на торговые операции
   community - признак соединения с комьюнити службой MQ
   balance   - соотв. баланс
   equity    - эквитя
   margin    - залог
   freemargin - свободный залог
   
   orders/+ - все рыночные ордера (если разрешены в параметрах) в виде json
**/
const int REVIEW_INTERVAL=5;     // интервал проверки изменения sl/tp ордеров и сработки отложек, секунд
const int HEATBEAT_INTERVAL=20;  // интервао "сердцебиения", секунд

string Prefix; // BasePath/AccountCompany/AccountId

datetime publishtime=0;

bool ready=false;
bool mqtt_connected=false;

bool connected=false;
bool tradeable=false;
double balance=0;
double equity=0;
double margin=0;
double freemargin=0;
bool community=false;

datetime publish_all_time=0;
#include <mt4mqtt/mt4mqtt.mqh>

class OrderInfo {
public:
   OrderInfo(int t) {
      gen=0;
      ticket=t;
      symbol=OrderSymbol();
      type=(ENUM_ORDER_TYPE)OrderType();
      openTime=OrderOpenTime();
      openPrice=OrderOpenPrice();
      stopLoss=OrderStopLoss();
      takeProfit=OrderTakeProfit();
      lots=OrderLots();      
      updateTime=0;
   }
   ~OrderInfo() {
   }
   string ToString() {
      // time buy xxx EURUSD price 
      string text = StringFormat("%u %s %.03f %s %.05f",(uint)openTime,OrderTypeToString(type),lots,symbol,openPrice);
      if (stopLoss!=0) {
         text+= StringFormat(" sl=%.05f",stopLoss);
      }
      if (takeProfit!=0) {
         text+= StringFormat(" tp=%.05f",takeProfit);
      }
      return text;
   }
public:
   ulong gen;
   int ticket;
   ENUM_ORDER_TYPE type;
   string symbol;
   datetime openTime;
   double openPrice,closePrice,stopLoss,takeProfit;
   double lots;
   datetime updateTime;
};
string OrderTypeToString(ENUM_ORDER_TYPE type)
{
   switch (type) {
      case OP_BUY: return "buy";
      case OP_BUYLIMIT: return "buylimit";
      case OP_BUYSTOP: return "buystop";
      case OP_SELL: return "sell";
      case OP_SELLLIMIT: return "selllimit";
      case OP_SELLSTOP: return "sellstop";
   }
   return EnumToString(type);
}
////
ulong generation=0;  // "поколение" - номер прохода при обзоре ордеров
OrderInfo *Orders[]; // коллекция ордеров

MQTT *mqtt;
string hb_topic=Prefix+"/hb";
string community_topic=Prefix+"/community";
string balance_topic=Prefix+"/balance";
string equity_topic=Prefix+"/equity";
string margin_topic=Prefix+"/margin";
string freemargin_topic=Prefix+"/freemargin";
string tradeable_topic=Prefix+"/tradeable";
string connected_topic=Prefix+"/connected";
string orders_topic=Prefix+"/orders";

void Reload()
{
   for(int pos=ArraySize(Orders)-1;pos>=0;pos--) {
      if (Orders[pos]!=NULL) delete Orders[pos];
   }
   ArrayResize(Orders,0);
   for(int pos=OrdersTotal()-1;pos>=0;pos--) {
      if (!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES)) continue;
      int id=ArraySize(Orders);
      ArrayResize(Orders,id+1);
      Orders[id]=new OrderInfo(OrderTicket());
   }
}
void PublishAll()
{
   if (!mqtt_connected) return;
   for(int id=ArraySize(Orders)-1;id>=0;id--) {
      if (Orders[id]==NULL) continue;
      PublishAndStore(Orders[id].ticket,Orders[id].ToString());
   }
}
void Activate()
{
   Reload();
   Prefix=BasePath+"/"+AccountCompany()+"/"+IntegerToString(AccountNumber());
   hb_topic=Prefix+"/hb";
   balance_topic=Prefix+"/balance";
   equity_topic=Prefix+"/equity";
   margin_topic=Prefix+"/margin";
   freemargin_topic=Prefix+"/freemargin";
   tradeable_topic=Prefix+"/tradeable";
   connected_topic=Prefix+"/connected";
   orders_topic=Prefix+"/orders";
   community_topic=Prefix+"/community";
   
   orders_topic=Prefix+"/orders";
   mqtt.Subscribe(orders_topic+"/+");
   
   balance=AccountBalance();
   equity=AccountEquity();
   margin=AccountMargin();
   freemargin=AccountFreeMargin();
   connected=IsConnected();
   tradeable=IsTradeAllowed();
   community=(bool)TerminalInfoInteger(TERMINAL_COMMUNITY_ACCOUNT) && (bool)TerminalInfoInteger(TERMINAL_COMMUNITY_CONNECTION);
   
   mqtt.Publish(connected_topic,(connected?"1":"0"),0,1);
   mqtt.Publish(tradeable_topic,(tradeable?"1":"0"),0,1);
   mqtt.Publish(community_topic,(community?"1":"0"),0,1);
   mqtt.Publish(balance_topic,StringFormat("%.05f",balance),0,1);
   mqtt.Publish(equity_topic,StringFormat("%.05f",equity),0,1);
   mqtt.Publish(margin_topic,StringFormat("%.05f",margin),0,1);
   mqtt.Publish(freemargin_topic,StringFormat("%.05f",freemargin),0,1);
   publish_all_time=TimeGMT()+15;
   ready=true; 
   DrawBanner();
}

int
on_connect(MQTT *instance)
{
   mqtt_connected=true;
   PrintFormat("TRAM Server %s connected",Server);
   if (ready || (!ready && AccountCompany()!="" && AccountNumber()!=0)) {
      ready=true;
      Activate();
   }
   if (ready) publish_all_time=TimeGMT()+15;
   DrawBanner();
   return 0;
}

int
on_disconnect(MQTT *instance,int reason)
{
   Alert("TRAM Server %s disconnected",Server);
   connected=false;
   balance=0;
   equity=0;
   margin=0;
   freemargin=0;
   publish_all_time=0;
   DrawBanner();
   return 0;
}
void PublishAndStore(string topic,string text)
{
   if (mqtt==NULL || !mqtt_connected) {
      return;
   }
   mqtt.Publish(topic,text,0,true);
}
void PublishAndStore(int ticket,string text)
{
   if (!ready) return;
   PublishAndStore(orders_topic+"/"+IntegerToString(ticket),text);   
}
int
on_message(MQTT *_mqtt,string topic,uchar &data[],int qos,int retain)
{
   string path[];
   if (StringFind(topic,Prefix)!=0) return 0;
   if (StringCompare(topic,hb_topic)==0) {
      // hb
   } else 
   if (StringCompare(topic,balance_topic)==0) {
      string local=DoubleToString(balance,5);
      string remote=CharArrayToString(data,0,WHOLE_ARRAY,CP_UTF8);
      if (local!=remote) {
         mqtt.Publish(balance_topic,local);
      }
   } else
   if (StringCompare(topic,equity_topic)==0) {
      string local=DoubleToString(equity,5);
      string remote=CharArrayToString(data,0,WHOLE_ARRAY,CP_UTF8);
      if (local!=remote) {
         mqtt.Publish(equity_topic,local);
      }
   } else
   if (StringCompare(topic,margin_topic)==0) {
      string local=DoubleToString(margin,5);
      string remote=CharArrayToString(data,0,WHOLE_ARRAY,CP_UTF8);
      if (local!=remote) {
         mqtt.Publish(margin_topic,local);
      }
   } else
   if (StringCompare(topic,freemargin_topic)==0) {
      string local=DoubleToString(freemargin,5);
      string remote=CharArrayToString(data,0,WHOLE_ARRAY,CP_UTF8);
      if (local!=remote) {
         mqtt.Publish(freemargin_topic,local);
      }
   } 
   if (StringFind(topic,orders_topic)==0 && retain) {
      string t=StringSubstr(topic,StringLen(orders_topic)+1);
      int ticket=(int)StringToInteger(t);
      int id=-1;
      for(id=ArraySize(Orders)-1;id>=0;id--) {
         if (Orders[id]==NULL) continue;
         if (Orders[id].ticket==ticket) break;
      }
      PrintFormat("Retain %s ticket=%d (%s) id=%d",topic,ticket,t,id);
      if (id==-1) {
         if (ArraySize(data)!=0) mqtt.Publish(topic,"",0,1);
      } else {
         string remote = CharArrayToString(data,0,WHOLE_ARRAY,CP_UTF8);
         string local  = Orders[id].ToString();
         if (local!=remote) {
            mqtt.Publish(topic,local,0,1);
         }
      }
   }
   return 0;
}
void HeatBeat()
{
   datetime gmt=TimeGMT();
   if (gmt>publishtime+5) {
      if (connected) {
         string message=IntegerToString(TimeGMT());
         mqtt.Publish(hb_topic,message);
         PublishBalance();
         publishtime=gmt;
      }
   }
}
void
PublishBalance()
{
   if (mqtt==NULL || !mqtt_connected) return;
   if (IsConnected()!=connected) {
      connected=IsConnected();
      mqtt.Publish(connected_topic,connected?"1":"0");
   }
   if (AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)!=tradeable) {
      tradeable=AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
      mqtt.Publish(tradeable_topic,tradeable?"1":"0");
   }
   if ((TerminalInfoInteger(TERMINAL_COMMUNITY_ACCOUNT) && TerminalInfoInteger(TERMINAL_COMMUNITY_CONNECTION))!=community) {
      community=TerminalInfoInteger(TERMINAL_COMMUNITY_ACCOUNT) && TerminalInfoInteger(TERMINAL_COMMUNITY_CONNECTION);
      mqtt.Publish(community_topic,community?"1":"0");
   }
   if (AccountBalance()!=balance) { 
      balance=AccountBalance();
      mqtt.Publish(balance_topic,DoubleToString(balance,3),0,1);
   }
   if (AccountFreeMargin()!=freemargin) { 
      freemargin=AccountFreeMargin();
      mqtt.Publish(freemargin_topic,DoubleToString(freemargin,3),0,1);
   }
   if (AccountMargin()!=margin) { 
      margin=AccountMargin();
      mqtt.Publish(margin_topic,DoubleToString(margin,3),1);
   }
   if (AccountEquity()!=equity) {
      equity=AccountEquity();
      mqtt.Publish(equity_topic,DoubleToString(equity,3),1);
   }
}

datetime review_gmt=0;
int review_orders_total=0;
int review_history_total=0;

void ScheduledReview()
{
   datetime gmt=TimeGMT();
   if (review_orders_total!=OrdersTotal() || review_history_total!=OrdersHistoryTotal() || gmt>review_gmt+REVIEW_INTERVAL) {
      review_gmt=gmt;
      review_orders_total=OrdersTotal();
      review_history_total=OrdersHistoryTotal();
      OrdersReview();
      PublishBalance();
   }
}
void OrdersReview()
{
   datetime modtime=TimeGMT();
   generation++;
   if (OrdersTotal()==0 && ArraySize(Orders)!=0) {
      for(int id=ArraySize(Orders)-1;id>=0;id--) {
         if (Orders[id]!=NULL) delete Orders[id];
      }
      ArrayResize(Orders,0);
      if (mqtt!=NULL && mqtt_connected) {
         mqtt.Publish(orders_topic,"");
      }
      return;
   }
   for(int pos=OrdersTotal()-1;pos>=0;pos--) {
      if (!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES)) {
         // какой-то ордер не смогли выбрать, результат непредсказуем 
         return;
      }
      int type=OrderType();
      if (type!=OP_BUY && type!=OP_BUYLIMIT && type!=OP_BUYSTOP &&
         type!=OP_SELL && type!=OP_SELLSTOP && type!=OP_SELLLIMIT) continue;
      
      // ищем ордер в массиве ордеров
      int id=-1;
      for(id=ArraySize(Orders)-1;id>=0;id--) {
         if (Orders[id]!=NULL && Orders[id].ticket==OrderTicket()) break;
      }
      if (id<0) {
         if (OrderCloseTime()!=0) continue;   
         // новый или не зарегестрированный ордер
         // выбрать пустой id или расширить массив Orders
         id=-1;
         for(id=ArraySize(Orders)-1;id>=0;id--) {
            if (Orders[id]==NULL) break;
         }
         if (id<0) {
            id=ArraySize(Orders);
            ArrayResize(Orders,id+1);
         }
         // создать новую запись и опубликовать
         Orders[id]=new OrderInfo(OrderTicket());
         PublishAndStore(Orders[id].ticket,Orders[id].ToString());
         Orders[id].gen=generation;
         continue;
      }
      Orders[id].gen=generation;
      if (OrderCloseTime()!=0) {
         // ордер закрылся, удалить из списка и опубликовать удаление
         // оформляем удаление
         PublishAndStore(Orders[id].ticket,"");
         // удаляем ордер из списка
         delete Orders[id];
         Orders[id]=NULL;
      } else {
         bool republish=false;
         if (OrderType() != Orders[id].type) republish=true;
         if (OrderOpenPrice() != Orders[id].openPrice) republish=true;
         if (OrderStopLoss() != Orders[id].stopLoss) republish=true;
         if (OrderTakeProfit() != Orders[id].takeProfit) republish=true;
         if (OrderLots() != Orders[id].lots) republish=true;
         Orders[id].type=(ENUM_ORDER_TYPE)OrderType();
         Orders[id].openPrice=OrderOpenPrice();
         Orders[id].stopLoss=OrderStopLoss();
         Orders[id].takeProfit=OrderTakeProfit();
         Orders[id].lots=OrderLots();
         if (republish /*|| Orders[id].updateTime+10<modtime*/) {
            Orders[id].updateTime=modtime;
            PublishAndStore(Orders[id].ticket,Orders[id].ToString());
            //PrintFormat("modified order %d",OrderTicket());
         }
      }
   }
   for(int id=ArraySize(Orders)-1;id>=0;id--) {
      if (Orders[id]!=NULL && Orders[id].gen!=generation) {
         // оформляем удаление
         PublishAndStore(Orders[id].ticket,"");
         // удаляем ордер из списка
         delete Orders[id];
         Orders[id]=NULL;
      }
   }
}
bool hasTimer=false;
int OnInit()
{
   //return INIT_FAILED;
   publish_all_time=0;
   Prefix="";
   ready=false;
   review_gmt=0;
   review_history_total=0;
   review_orders_total=0;

   connected=false;
   tradeable=false;
   balance=0;
   equity=0;
   margin=0;
   freemargin=0;
   
   string cert="";
/*   if (Login!="" && Password!="") {
      cert=TerminalInfoString(TERMINAL_COMMONDATA_PATH)+"\\cacert.pem";
      if (!FileIsExist(cert)) {
         Alert("cacert.pem not found");
         cert="";
      }
   }*/
   mqtt=new MQTT(Login,Password,cert,Server);
   mqtt.SetCallbacks(on_message,on_connect,on_disconnect);

   hasTimer=EventSetMillisecondTimer(250);
   DrawBanner();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   for(int id=ArraySize(Orders)-1;id>=0;id--) {
      if (Orders[id]!=NULL) delete Orders[id];
   }
   ObjectsDeleteAll(0,"tram.");
   delete mqtt;
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
   if (!hasTimer) {
      hasTimer=EventSetMillisecondTimer(250);
   }
   ScheduledReview();
   if (mqtt!=NULL) {
      mqtt.Loop();
   }
   HeatBeat();
   return(rates_total);
}

void OnTimer()
{
   datetime gmt=TimeGMT();
   if (publish_all_time!=0 && publish_all_time<gmt) {
      publish_all_time=0;
      PublishAll();
   }
   ScheduledReview();
   if ((!ready) && mqtt_connected && AccountCompany()!="" && AccountNumber()!=0) {
      Activate();
   }
   mqtt.Loop();
   HeatBeat();
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   ScheduledReview();
   mqtt.Loop();
   HeatBeat();
}

void DrawBanner()
{
   string obj="tram.banner";
   if (ObjectType(obj)==OBJ_LABEL || ObjectCreate(0,obj,OBJ_LABEL,0,0,0)) {
      string text=StringFormat("TRAM v0.1 -> %s %s",Server,BasePath);
      ObjectSetInteger(0,obj,OBJPROP_XDISTANCE,200);
      ObjectSetInteger(0,obj,OBJPROP_YDISTANCE,20);
      ObjectSetString(0,obj,OBJPROP_TEXT,text);
      ObjectSetString(0,obj,OBJPROP_FONT,"Arial Black");
      ObjectSetInteger(0,obj,OBJPROP_FONTSIZE,12);
      if (mqtt_connected && !ready) {
         ObjectSetInteger(0,obj,OBJPROP_COLOR,clrDarkOrange);
      } else if (mqtt_connected) {
         ObjectSetInteger(0,obj,OBJPROP_COLOR,clrDarkGreen);
      } else {
         ObjectSetInteger(0,obj,OBJPROP_COLOR,clrDarkGray);
      }
      ObjectSetInteger(0,obj,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,obj,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,obj,OBJPROP_SELECTED,false);
   }
}