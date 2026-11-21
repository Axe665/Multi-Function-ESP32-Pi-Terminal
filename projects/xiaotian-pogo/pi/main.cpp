#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QCommandLineParser>
#include <QTimer>
#include <QImage>
#include <QDir>
#include <QFontDatabase>
#include <QQuickStyle>
#include <QPalette>
#include <cstdio>
#include "controller.h"

int main(int argc,char **argv) {
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc,argv);
    // Explicit CJK font keeps the Windows and Linux/offscreen previews legible.
#ifdef Q_OS_WIN
    QFontDatabase::addApplicationFont("C:/Windows/Fonts/msyh.ttc");
    app.setFont(QFont("Microsoft YaHei"));
#else
    for(const QString &name:{QStringLiteral("Noto Sans CJK SC"),QStringLiteral("WenQuanYi Micro Hei")})
        if(QFontDatabase::families().contains(name)){app.setFont(QFont(name));break;}
#endif
    QPalette palette;
    palette.setColor(QPalette::Window,QColor("#101b29"));palette.setColor(QPalette::WindowText,QColor("#e1edf7"));
    palette.setColor(QPalette::Button,QColor("#294457"));palette.setColor(QPalette::ButtonText,QColor("#e1edf7"));
    palette.setColor(QPalette::Base,QColor("#132432"));palette.setColor(QPalette::Text,QColor("#e1edf7"));
    palette.setColor(QPalette::Highlight,QColor("#39b998"));palette.setColor(QPalette::HighlightedText,QColor("#102027"));
    app.setPalette(palette);
    app.setOrganizationName("PiBridge");app.setApplicationName("XiaotianBaseline");
    QCommandLineParser parser;parser.addHelpOption();
    parser.addOptions({{"demo","Explicit simulated data; no hardware access"},
        {"device","Private pairing JSON","file"},{"host","ESP IP override","ip"},
        {"serial","Bench USB port","port"},{"python","Python executable","path","python3"},
        {"worker","worker.py path","path"},{"record-dir","Private recording directory","dir"},
        {"screenshot","Save demo screenshot and exit","file"},{"self-test","Exercise demo UI and exit"},
        {"smoke-live","Verify real worker->QML status, enable and disable, then exit"}});
    parser.process(app);
    bool demo=parser.isSet("demo");
    if(!demo&&(parser.isSet("device")==parser.isSet("serial")||!parser.isSet("worker"))) {
        std::fputs("Use --demo, or --worker path plus exactly one --device/--serial.\n",stderr);return 2;
    }
    IRController controller(demo);
    QStringList args;
    for(const auto &key:{"device","host","serial","record-dir"})if(parser.isSet(key))args<<QString("--")+key<<parser.value(key);
    if(!demo)controller.start(parser.value("python"),parser.value("worker"),args);
    QQmlApplicationEngine engine;engine.rootContext()->setContextProperty("irController",&controller);
    engine.load(QUrl("qrc:/qml/Main.qml"));if(engine.rootObjects().isEmpty())return 3;
    if(parser.isSet("smoke-live")&&!demo) {
        auto timer=new QTimer(&app);timer->setInterval(250);
        int phase=0;
        QObject::connect(timer,&QTimer::timeout,&app,[&]{
            if(!controller.online()||controller.busy())return;
            auto data=controller.data();
            if(phase==0) {
                if(data.value("version").toString()!="2.1.0"){app.exit(6);return;}
                controller.setEnabled(true);phase=1;
            } else if(phase==1&&data.value("enabled").toBool()) {
                controller.setEnabled(false);phase=2;
            } else if(phase==2&&!data.value("enabled").toBool()) {
                std::puts("PASS: live ESP->USB->Python->Qt/QML status/enable/disable; final standby");app.exit(0);
            }
        });
        timer->start();
        QTimer::singleShot(20000,&app,[&]{std::fputs("FAIL: live UI timeout\n",stderr);app.exit(7);});
        // phase lives until app.exec() returns below.
        return app.exec();
    } else if(parser.isSet("self-test")&&demo) {
        QTimer::singleShot(300,&app,[&]{
            controller.demoTogglePogo();controller.demoToggleBeam();
            bool good=controller.data().value("enabled").toBool()&&!controller.data().value("pogo").toMap().value("wired").toBool()
                &&controller.data().value("state").toString()=="blocked";
            controller.setAuthenticatedUser("demo-user");controller.setRecording(true);
            controller.setAuthenticatedUser("");
            good=good&&!controller.data().value("recording").toBool()&&controller.data().value("enabled").toBool();
            controller.setEnabled(false);
            auto button=engine.rootObjects().first()->findChild<QObject *>("enableButton");
            good=good&&button&&button->property("enabled").toBool();
            controller.setEnabled(true);
            good=good&&controller.data().value("enabled").toBool();
            std::puts(good?"PASS: QML loaded/contact-independent/beam/logout/re-enable":"FAIL");
            app.exit(good?0:4);
        });
    } else if(parser.isSet("screenshot")&&demo) {
        QTimer::singleShot(1200,&app,[&]{
            auto window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());
            bool ok=window&&window->grabWindow().save(parser.value("screenshot"));app.exit(ok?0:5);
        });
    }
    return app.exec();
}
