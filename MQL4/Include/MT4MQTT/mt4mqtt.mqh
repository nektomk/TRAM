//+------------------------------------------------------------------+
//|                                                      mt4mqtt.mqh |
//|                                  Copyright 2018, Maxim Kuznetsov |
//|                                          https://www.luxtrade.tk |
//+------------------------------------------------------------------+
#property copyright "Copyright 2018, Maxim Kuznetsov"
#property link      "https://www.luxtrade.tk"
#property strict

class MQTT;

// чтобы не заставлять пользователя порождать ненужные ему классы
// позволим ему задавать колбеки :-)

// вот такая функция будет вызывать при поступлении сообщений от брокера
typedef int (*MQTT_OnMessage)(MQTT *,string topic,uchar &data[],int qos,int retain);
// такая при установке соединение
typedef int (*MQTT_OnConnect)(MQTT *);
// а такая при разрыве
typedef int (*MQTT_OnDisconnect)(MQTT *,int);

class MQTT {
public:
   // создать подключение к брокеру
   MQTT(string server="localhost",string persistentDir="");
   MQTT(string login,string pass,string cert,string server="localhost",string persistentDir="");
   // задать собственные колбеки для событий
   int SetCallbacks(MQTT_OnMessage callback,MQTT_OnConnect on_connect,MQTT_OnDisconnect on_disconnect);
   // подписаться на темы
   int Subscribe(string topic);
   // опубликовать сообщение в теме
   int Publish(string topic,uchar &data[],int data_size,int qos=0,bool retain=false);
   // (для пущего удобства) опубликовать текстовое сообщение
   int Publish(string topic,string text,int qos=0,bool retain=false);
   // время от времени надо запускать Loop
   int Loop();
   
   ~MQTT();
protected:
   int id;  // рабочий идентификатор
   bool connected; // признак есть/нет соединение
   // кол-беки
   MQTT_OnMessage on_message;
   MQTT_OnConnect on_connect;
   MQTT_OnDisconnect on_disconnect;
};

#import "MT4MQTT/mt4mqtt.dll"
	int MQTT_New(string ,string);
	int MQTT_New2(string,string,string,string ,string);
	int MQTT_Destroy(int);
	int MQTT_Subscribe(int,string,int);
	int MQTT_Publish(int,string ,uchar &[] ,int,int,int);
	int MQTT_Receive(int,int &meta[4]);
	int MQTT_CopyMessage(int,string &,uchar &[]);
	int MQTT_IsConnected(int);
	int UUID_Generate(uchar &store[36]);
#import

MQTT::MQTT(string _server,string _persistDir)
{
   id = MQTT_New(_server,_persistDir);
   on_message=NULL;
   on_connect=NULL;
   on_disconnect=NULL;
}
MQTT::MQTT(string _login,string _pass,string _cert,string _server,string _persistDir)
{
   id = MQTT_New2(_login,_pass,_cert,_server,_persistDir);
   on_message=NULL;
   on_connect=NULL;
   on_disconnect=NULL;
}
MQTT::~MQTT()
{
   MQTT_Destroy(id);
}
int
MQTT::SetCallbacks(MQTT_OnMessage _on_message,MQTT_OnConnect _on_connect,MQTT_OnDisconnect _on_disconnect)
{
   on_message=_on_message;
   on_disconnect=_on_disconnect;
   if (on_connect == NULL && _on_connect!=NULL && connected) {
      on_connect=_on_connect;
      on_connect(&this);
   } else {
      on_connect=_on_connect;
   }
   return 0;
}
int
MQTT::Subscribe(string topic)
{
   if (id==0) return -1;
   return MQTT_Subscribe(id,topic,0);
}
int
MQTT::Publish(string topic,string text,int qos,bool retain)
{
   if (id==0) return -1;
   uchar data[];
   int data_size=StringToCharArray(text,data,0,WHOLE_ARRAY,CP_UTF8);
   return MQTT_Publish(id,topic,data,data_size-1,qos,retain);
}
int 
MQTT::Publish(string topic,uchar &data[],int data_size,int qos,bool retain)
{
   if (id==0) return -1;
   return MQTT_Publish(id,topic,data,data_size,qos,retain);   
}
int 
MQTT::Loop()
{
   int meta[4];
   string topic; 
   uchar payload[];
   if (!connected && MQTT_IsConnected(id)) {
      connected=true;
      if (on_connect!=NULL) on_connect(&this);
   }
   while(MQTT_Receive(id,meta)) {
      if (on_message!=NULL) {
         // резервировать пространство в строках
         StringReserve(topic,meta[0]);
         ArrayResize(payload,meta[1]);
         MQTT_CopyMessage(id,topic,payload);
         StringSetLength(topic,meta[0]);
         on_message(&this,topic,payload,meta[2],meta[3]);
      }
      //MQTT_MessageDone(id,msgid);
   }
   if (connected && !MQTT_IsConnected(id)) {
      connected=false;
      if (on_disconnect!=NULL) on_disconnect(&this,0);
   }
   return 0;
}

string UuidCreate()
{
   uchar store[36];
   int s=UUID_Generate(store);
   if (s!=36) return "";
   return CharArrayToString(store);
}
