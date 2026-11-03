// 模块网络 broker 的边界：按 appId 授权、只允许 HTTP(S) 公网、
// 阻断 QML NAM 的直接请求。公网连通性由代理测试覆盖，这里不依赖外网。
#include <QtTest>
#include <QNetworkReply>
#include <QNetworkAccessManager>
#include <QQmlNetworkAccessManagerFactory>
#include <QSignalSpy>

#include "core/AppNetworkApi.h"
#include "core/AppNetworkBroker.h"

class AppNetworkBrokerTest : public QObject {
    Q_OBJECT
private slots:
    void deniesPrivateAndNonHttpDestinations()
    {
        AppNetworkBroker broker([](const QString &app) { return app == QStringLiteral("ok"); });
        QString why;
        QVERIFY(!broker.permits(QStringLiteral("ok"), QUrl(QStringLiteral("http://127.0.0.1")), &why));
        QVERIFY(!why.isEmpty());
        QVERIFY(!broker.permits(QStringLiteral("ok"), QUrl(QStringLiteral("http://10.0.0.1"))));
        QVERIFY(!broker.permits(QStringLiteral("ok"), QUrl(QStringLiteral("http://192.168.1.1"))));
        QVERIFY(!broker.permits(QStringLiteral("ok"), QUrl(QStringLiteral("http://169.254.1.1"))));
        QVERIFY(!broker.permits(QStringLiteral("ok"), QUrl(QStringLiteral("https://localhost"))));
        QVERIFY(!broker.permits(QStringLiteral("ok"), QUrl(QStringLiteral("ftp://example.com"))));
        QVERIFY(!broker.permits(QStringLiteral("denied"), QUrl(QStringLiteral("https://example.com"))));
    }

    void deniedRequestFailsClosed()
    {
        AppNetworkBroker broker([](const QString &) { return false; });
        QJsonObject response;
        bool called = false;
        broker.request(QStringLiteral("anything"),
                       {{QStringLiteral("url"), QStringLiteral("https://example.com")}},
                       [&](const QJsonObject &value) { called = true; response = value; });
        QVERIFY(called);
        QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
        QVERIFY(!response.value(QStringLiteral("error")).toString().isEmpty());
    }

    void qmlNamBlocksDirectRequests()
    {
        AppNetworkBroker broker([](const QString &app) { return app == QStringLiteral("ok"); });
        AppNetworkApi api(&broker, QStringLiteral("ok"));
        QVERIFY(api.allowed());
        QScopedPointer<QQmlNetworkAccessManagerFactory> factory(api.createNamFactory(nullptr));
        QVERIFY(factory);
        QScopedPointer<QNetworkAccessManager> manager(factory->create(nullptr));
        QVERIFY(manager);
        QNetworkReply *reply = manager->get(
            QNetworkRequest(QUrl(QStringLiteral("http://127.0.0.1:3000/"))));
        QSignalSpy finished(reply, &QNetworkReply::finished);
        QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, 3000);
        QCOMPARE(reply->error(), QNetworkReply::ContentAccessDenied);
        reply->deleteLater();
    }

    void explicitApiEmitsFailureForPrivateUrl()
    {
        AppNetworkBroker broker([](const QString &app) { return app == QStringLiteral("ok"); });
        AppNetworkApi api(&broker, QStringLiteral("ok"));
        QSignalSpy finished(&api, &AppNetworkApi::finished);
        api.request({{QStringLiteral("url"), QStringLiteral("http://127.0.0.1")}});
        QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, 3000);
        const QVariantMap response = finished.first().at(1).toMap();
        QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
    }
};

QTEST_GUILESS_MAIN(AppNetworkBrokerTest)
#include "app_network_broker_test.moc"
