//+------------------------------------------------------------------+
//|                                               AccountMonitor.mq4 |
//|                                Copyright 2020, Maxim A.Kuznetsov |
//|                                          https://www.luxtrade.tk |
//+------------------------------------------------------------------+
#property copyright "Copyright 2020, Maxim A.Kuznetsov"
#property link      "https://www.luxtrade.tk"
#property version   "1.00"
#property strict
#property indicator_chart_window
//--- input parameters
input string   Server="test.mosquitto.org";
//const string   Server="localhost";
const string   Root="AccountMonitor012021";
input string   ID="Max";
/***
   Информация записывается в следующем виде
   {Root}/talk/{ID} - просто широковещательные сообщения ото всех
   {Root}/users/{ID} - "куст" конкретного пользователя
   {Root}/users/{ID}/{Company}/{Account} - куст отдельного аккаунта
               hb - "heatbeat" - периодически обновляемая метка времени GMT, секунд с начала эпохи (unixtime)
               localTime - локальное время на компьютере, строка
               serverTime - последнее известное время сервера, строка
               connected - 0/1 есть/нет соединения с торговым сервером
               tradeAllowed - 0/1 разрешена/нет торговля в акк.
               wallets/{Currency} - актуальные данные по балансу
                       balance - баланс
                       equity  - эквити
                       freeMargin тоже понятно что
   ToDo: проверить reconnect                       
**/                                  
string Prefix; // AccountCompany/AccountId

datetime publishtime=0;

bool connected=false;
bool mtConnected=false;
bool tradeAllowed=false;

string textEntry="accMon.textEntry";   // сюда вводим текст
string sendButton="accMon.sendButton"; // жмём кпоку и он отсылается

double balance=0;
double equity=0;
double freemargin=0;

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
   void Publish() {
      string topic=StringFormat("%s/%s/orders/%d",Root,Prefix,ticket);
      int digits=(int)MarketInfo(symbol,MODE_DIGITS);
      string message=StringFormat("{symbol=%s,type=%s,lots=%s,openPrice=%s,stopLoss=%s,takeProfit=%s,openTime=%s,modTime=%s}",
         symbol,
         OrderTypeToString(type),
         DoubleToString(lots,3),
         DoubleToString(openPrice,digits),
         DoubleToString(stopLoss,digits),
         DoubleToString(takeProfit,digits),
         IntegerToString(openTime+TimeGMTOffset()),
         IntegerToString(TimeGMT())
         );
      if (connected) {
         mqtt.Publish(topic,message,true);
      }
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
int
on_connect(MQTT *instance)
{
   Alert(StringFormat("%s connected",Server));
   Prefix=ID+"/"+AccountCurrency()+"/"+AccountCompany()+"/"+IntegerToString(AccountNumber());
   string talk=StringFormat("%s/talk/+",Root);
   mqtt.Subscribe(talk);
   string orders=StringFormat("%s/%s/orders/+",Root,Prefix);
   mqtt.Subscribe(orders);
   connected=true;
   mtConnected=IsConnected();
   tradeAllowed=(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
   string topic=StringFormat("%s/%s/connected",Root,Prefix);
   mqtt.Publish(topic,mtConnected?"1":"0");
   topic=StringFormat("%s/%s/tradeAllowed",Root,Prefix);
   mqtt.Publish(topic,tradeAllowed?"1":"0");
   for(int id=ArraySize(Orders)-1;id>=0;id--) {
      if (Orders[id]!=NULL) {
         delete Orders[id];
         Orders[id]=NULL;
      }
   }
   return 0;
}

int
on_disconnect(MQTT *instance,int reason)
{
   Alert(StringFormat("%s disconncted",Server));
   connected=false;
   balance=0;
   equity=0;
   freemargin=0;
   return 0;
}
int
on_message(MQTT *_mqtt,string topic,uchar &data[],int qos,int retain)
{
   string path[];
   int pathLen=StringSplit(topic,'/',path);
   if (path[0]==Root) {
      // получено сообщение в наш "куст"
      // Root/talk/author
      if (pathLen==3 && path[1]=="talk") {
         // сообщение в Root/talk/Author
         // выделяем автора
         string author=path[2];
         Alert(StringFormat("%s say %s",author,CharArrayToString(data,0,WHOLE_ARRAY,CP_UTF8)));
      } else if (pathLen==7 && path[1]==ID && path[2]==AccountCurrency() && path[3]==AccountCompany() && path[4]==IntegerToString(AccountNumber()) && path[5]=="orders") {
         // Root/ID/Currency/Company/Account/orders/{order}
         // получено сообщение про собственные ордера в торговле
         // возможно они retain то есть сохранились на сервере
         // Root/ID/orders/ticket
         long ticket=StringToInteger(path[6]);
         if (ArraySize(data)!=0) {
            if (OrderSelect((int)ticket,SELECT_BY_TICKET) && (OrderCloseTime()!=0)) {
               mqtt.Publish(topic,"");
               for(int id=ArraySize(Orders)-1;id>=0;id--) {
                  if (Orders[id]!=NULL && Orders[id].ticket==ticket) {
                     delete Orders[id];
                     Orders[id]=NULL;
                     PrintFormat("remove retained %d",ticket);
                     break;
                  }
               }
            }
         } else if (ArraySize(data)==0) {
            for(int id=ArraySize(Orders)-1;id>=0;id--) {
               if (Orders[id]!=NULL && Orders[id].ticket==ticket) {
                  delete Orders[id];
                  Orders[id]=NULL;
                  PrintFormat("clear by server %d",ticket);
                  break;
               }
            }
         }
      }
   } else {
      //Alert("message from %s",topic);
   }
   return 0;
}
void HeatBeat()
{
   datetime gmt=TimeGMT();
   if (gmt>publishtime+5) {
      if (connected) {
         string topic=StringFormat("%s/%s/hb",Root,Prefix);
         string message=IntegerToString(TimeGMT());
         mqtt.Publish(topic,message);
         mqtt.Loop();
         topic=StringFormat("%s/%s/timeLocal",Root,Prefix);
         message=TimeToString(TimeLocal(),TIME_DATE|TIME_MINUTES|TIME_SECONDS);
         mqtt.Publish(topic,message);
         mqtt.Loop();
         topic=StringFormat("%s/%s/timeCurrent",Root,Prefix);
         message=TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES|TIME_SECONDS);
         mqtt.Publish(topic,message);
         PublishBalance();
         publishtime=gmt;
      }
   }
}
void
PublishBalance()
{
   if (true || IsConnected()!=mtConnected) {
      mtConnected=IsConnected();
      string topic=StringFormat("%s/%s/connected",Root,Prefix);
      mqtt.Publish(topic,mtConnected?"1":"0");
   }
   if (true || AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)!=tradeAllowed) {
      tradeAllowed=AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
      string topic=StringFormat("%s/%s/tradeAllowed",Root,Prefix);
      mqtt.Publish(topic,tradeAllowed?"1":"0");
   }
   if (true || AccountBalance()!=balance) { 
      balance=AccountBalance();
      string topic=StringFormat("%s/%s/balance",Root,Prefix);
      mqtt.Publish(topic,DoubleToString(balance,3),1);
   }
   if (true || AccountEquity()!=equity) {
      equity=AccountEquity();
      string topic=StringFormat("%s/%s/equity",Root,Prefix);
      mqtt.Publish(topic,DoubleToString(equity,3),1);
   }
   if (true || AccountFreeMargin()!=freemargin) {
      freemargin=AccountFreeMargin();
      string topic=StringFormat("%s/%s/freemagin",Root,Prefix);
      mqtt.Publish(topic,DoubleToString(AccountFreeMargin(),3),1);
   }
   
}
void OrdersReview()
{
   datetime modtime=TimeGMT();
   if (!connected) {
      return;
   }
   generation++;
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
         Orders[id].Publish();
         Orders[id].gen=generation;
         PrintFormat("new order %d",OrderTicket());
         continue;
      }
      Orders[id].gen=generation;
      if (OrderCloseTime()!=0) {
         // ордер закрылся, удалить из списка и опубликовать удаление
         // оформляем удаление
         string topic=StringFormat("%s/%s/orders/%d",Root,Prefix,OrderTicket());
         mqtt.Publish(topic,"");
         // удаляем ордер из списка
         delete Orders[id];
         Orders[id]=NULL;
         PrintFormat("closed 2 order %d",OrderTicket());
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
         if (republish || Orders[id].updateTime+10<modtime) {
            Orders[id].updateTime=modtime;
            Orders[id].Publish();
            //PrintFormat("modified order %d",OrderTicket());
         }
      }
   }
   for(int id=ArraySize(Orders)-1;id>=0;id--) {
      if (Orders[id]!=NULL && Orders[id].gen!=generation) {
         // оформляем удаление
         string topic=StringFormat("%s/%s/orders/%d",Root,Prefix,OrderTicket());
         mqtt.Publish(topic,"");
         // удаляем ордер из списка
         delete Orders[id];
         Orders[id]=NULL;
         PrintFormat("closed 1 order %d",OrderTicket());
      }
   }
}
int OnInit()
{
   Prefix=ID+"/"+AccountCurrency()+"/"+AccountCompany()+"/"+IntegerToString(AccountNumber());
   connected=false;
   balance=0;
   equity=0;
   freemargin=0;
   mqtt=new MQTT(Server);
   mqtt.SetCallbacks(on_message,on_connect,on_disconnect);
   EventSetMillisecondTimer(100);
   ObjectsDeleteAll(0,"accMon.");
   string name=textEntry;
   ObjectCreate(0,name,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,500);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,600);
   name=sendButton;
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,100);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,100);
   ObjectSetString(0,name,OBJPROP_TEXT,"SEND");
   ChartRedraw();
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason)
{
   for(int id=ArraySize(Orders)-1;id>=0;id--) {
      if (Orders[id]!=NULL) delete Orders[id];
   }
   ObjectsDeleteAll(0,"accMon.");
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
   mqtt.Loop();
   HeatBeat();
   return(rates_total);
}
void OnTimer()
{
   mqtt.Loop();
   HeatBeat();
   if (connected) OrdersReview();
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if ((id==CHARTEVENT_OBJECT_CLICK && sparam==sendButton) || (id==CHARTEVENT_OBJECT_ENDEDIT && sparam==textEntry)) {
      if (connected) {
         string topic=StringFormat("%s/talk/%s",Root,ID);
         string message=ObjectGetString(0,textEntry,OBJPROP_TEXT);
         message=StringTrimLeft(StringTrimRight(message));
         if (message!="") {
            mqtt.Publish(topic,message);
         }
         ObjectSetString(0,textEntry,OBJPROP_TEXT,"");
      }
      ObjectSetInteger(0,sendButton,OBJPROP_STATE,0);
   }
   mqtt.Loop();
   HeatBeat();
}
