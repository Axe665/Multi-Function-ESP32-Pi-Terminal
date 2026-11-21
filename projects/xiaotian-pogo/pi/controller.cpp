#include "controller.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QDateTime>
#include <QFileInfo>
#include <QCryptographicHash>
#include <QtMath>

IRController::IRController(bool demo,QObject *parent):QObject(parent),m_demo(demo) {
    useDeviceLayout(demo?"demo":"unbound");
    m_stale.setSingleShot(true); m_stale.setInterval(4500);
    connect(&m_stale,&QTimer::timeout,this,[this]{m_online=false;m_message=QStringLiteral("数据超时，状态未知");emit changed();});
    connect(&m_worker,&QProcess::readyReadStandardOutput,this,&IRController::readReplies);
    connect(&m_worker,&QProcess::errorOccurred,this,[this](QProcess::ProcessError){
        m_online=false;m_busy=false;m_message=QStringLiteral("接收程序启动或通信失败，请检查 Python 与配对文件");emit changed();});
    connect(&m_worker,qOverload<int,QProcess::ExitStatus>(&QProcess::finished),this,[this](int,QProcess::ExitStatus){
        m_online=false;m_busy=false;m_message=QStringLiteral("接收程序已退出，设备状态未知");emit changed();});
    if(demo) {
        m_online=true;
        m_data={{"device_id","demo"},{"version","2.1.0"},{"enabled",true},{"state","clear"},
                {"stable",1},{"recording",false},{"changes",0},
                {"pogo",QVariantMap{{"wired",true},{"ready",true}}}};
        m_message=QStringLiteral("演示数据 · 未连接真实设备");
    } else m_message=QStringLiteral("等待设备数据");
}
IRController::~IRController() {
    // EOF asks the worker to stop the personal session. Monitoring stays enabled.
    m_worker.closeWriteChannel();
    if(!m_worker.waitForFinished(1500)) { m_worker.terminate();m_worker.waitForFinished(1000); }
}
void IRController::start(const QString &python,const QString &worker,const QStringList &args) {
    if(m_demo) return;
    m_worker.setProgram(python);m_worker.setArguments(QStringList{worker}+args);m_worker.start();
}
void IRController::send(const QVariantMap &command) {
    if(m_demo||m_busy) return;
    if(m_worker.state()!=QProcess::Running) {m_message=QStringLiteral("接收程序未运行");emit changed();return;}
    m_busy=true;m_message=QStringLiteral("等待设备确认…");emit changed();
    m_worker.write(QJsonDocument::fromVariant(command).toJson(QJsonDocument::Compact)+'\n');
}
void IRController::setEnabled(bool enabled) {
    if(m_demo) {m_data["enabled"]=enabled;m_data["state"]=enabled?"clear":"unknown";m_data["recording"]=false;emit changed();return;}
    send({{"op",enabled?"enable":"disable"}});
}
void IRController::setRecording(bool enabled) {
    if(enabled&&!m_authenticated) {m_message=QStringLiteral("请先通过终端完成身份认证");emit changed();return;}
    if(m_demo) {m_data["recording"]=enabled;emit changed();return;}
    send({{"op",enabled?"record_start":"record_stop"}});
}
void IRController::setAuthenticatedUser(const QString &user) {
    if(m_demo) {m_authenticated=!user.isEmpty();if(!m_authenticated)m_data["recording"]=false;emit changed();return;}
    // Login/logout may never be silently dropped behind an enable request.
    if(m_worker.state()!=QProcess::Running) return;
    m_authenticated=!user.isEmpty();
    if(user.isEmpty())m_data["recording"]=false;
    QVariantMap command{{"op",user.isEmpty()?"logout":"login"}};
    if(!user.isEmpty())command["user_key"]=user;
    m_worker.write(QJsonDocument::fromVariant(command).toJson(QJsonDocument::Compact)+'\n');emit changed();
}
void IRController::useDeviceLayout(const QString &id) {
    m_device=id;
    QString group="layout/"+QString::fromLatin1(QCryptographicHash::hash(id.toUtf8(),QCryptographicHash::Sha256).toHex());
    m_settings.beginGroup(group);
    m_placement={{"name",m_settings.value("name",QStringLiteral("实验室入口"))},
        {"x",m_settings.value("x",0.5)},{"y",m_settings.value("y",0.5)},
        {"angle",m_settings.value("angle",0.0)},{"length",m_settings.value("length",0.45)}};
    m_settings.endGroup();emit placementChanged();
}
void IRController::setPlacement(const QString &name,double x,double y,double angle,double length) {
    if(!qIsFinite(x)||!qIsFinite(y)||!qIsFinite(angle)||!qIsFinite(length))return;
    m_placement={{"name",name.left(64)},{"x",qBound(0.05,x,0.95)},{"y",qBound(0.05,y,0.95)},
        {"angle",qBound(-180.0,angle,180.0)},{"length",qBound(0.15,length,0.7)}};
    m_settings.beginGroup("layout/"+QString::fromLatin1(QCryptographicHash::hash(m_device.toUtf8(),QCryptographicHash::Sha256).toHex()));
    for(auto i=m_placement.begin();i!=m_placement.end();++i)m_settings.setValue(i.key(),i.value());
    m_settings.endGroup();m_settings.sync();emit placementChanged();
}
void IRController::readReplies() {
    m_buffer+=m_worker.readAllStandardOutput();
    if(m_buffer.size()>262144) {m_buffer.clear();m_online=false;emit changed();return;}
    int newline;
    while((newline=m_buffer.indexOf('\n'))>=0) {
        auto line=m_buffer.left(newline);m_buffer.remove(0,newline+1);
        auto doc=QJsonDocument::fromJson(line);if(!doc.isObject())continue;
        auto reply=doc.object();QString type=reply.value("type").toString();
        if(type=="status") {
            auto data=reply.value("data").toObject().toVariantMap();
            QString id=data.value("device_id").toString();
            if(id.isEmpty()||data.value("schema").toString()!="xiaotian.node.v2")continue;
            if(id!=m_device)useDeviceLayout(id);
            m_data=data;m_online=true;m_authenticated=reply.value("authenticated").toBool();
            m_stale.start();if(!m_busy)m_message=QStringLiteral("实时连接 · 触点拔开不影响无线监测");
        } else if(type=="offline") {
            m_online=false;m_message=reply.value("message").toString();m_data["recording"]=false;
        } else if(type=="ack") {
            m_busy=false;m_message=reply.value("ok").toBool()?QStringLiteral("操作已确认"):QStringLiteral("操作失败：")+reply.value("message").toString();
            if(!reply.value("ok").toBool()&&reply.value("op").toString()=="login")m_authenticated=false;
        } else if(type=="error")m_message=reply.value("message").toString();
        emit changed();
    }
}
void IRController::demoToggleBeam() {
    if(!m_demo||!m_data.value("enabled").toBool())return;
    bool blocked=m_data.value("state").toString()!="blocked";
    m_data["state"]=blocked?"blocked":"clear";m_data["stable"]=blocked?0:1;
    m_data["changes"]=m_data.value("changes").toInt()+1;emit changed();
}
void IRController::demoTogglePogo() {
    if(!m_demo)return;auto pogo=m_data.value("pogo").toMap();pogo["wired"]=!pogo.value("wired").toBool();m_data["pogo"]=pogo;emit changed();
}
