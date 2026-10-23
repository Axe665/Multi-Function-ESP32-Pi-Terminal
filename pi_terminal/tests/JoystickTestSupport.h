#pragma once

#include <QObject>
#include <QQuickItem>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QJSValue>
#include <QStringList>

// Shared fixtures for BrowserJoystick tests: a minimal systemTools stand-in
// (I18n only reads uiLanguage) and a WebEngineView stand-in that records the
// injected JavaScript and navigation calls.

class JoystickTools : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString uiLanguage MEMBER language NOTIFY languageChanged)
public:
    QString language = QStringLiteral("zh");
    // MaterialIcon resolves its image source through this API; returning a URL
    // is enough even when the icon file itself is absent in minimal harnesses.
    Q_INVOKABLE QString monochromeIcon(const QString &, bool) const {
        return QStringLiteral("qrc:/icons/material/light/apps.svg");
    }
signals:
    void languageChanged();
};

class FakeWebView : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(bool canGoBack READ canGoBack WRITE setCanGoBack NOTIFY canGoBackChanged)
public:
    QStringList jsCalls;
    int backCalls = 0;
    int reloadCalls = 0;

    bool canGoBack() const { return canGoBack_; }
    void setCanGoBack(bool value) {
        if (canGoBack_ == value) return;
        canGoBack_ = value;
        emit canGoBackChanged();
    }
    Q_INVOKABLE void runJavaScript(const QString &code, const QJSValue &callback) {
        jsCalls << code;
        if (callback.isCallable()) callback.call();
    }
    Q_INVOKABLE void goBack() { ++backCalls; }
    Q_INVOKABLE void reload() { ++reloadCalls; }
signals:
    void canGoBackChanged();
private:
    bool canGoBack_ = true;
};

// Instantiates BrowserJoystick from the module resources, sized and wired to
// the fake view. Returns nullptr on failure (component error reported by QTest
// macros at the call site via errorString out-parameter).
inline QQuickItem *makeJoystick(QQmlEngine &engine, JoystickTools &tools, FakeWebView &fake,
                                const QSize &size, QString *errorString) {
    engine.rootContext()->setContextProperty("systemTools", &tools);
    engine.rootContext()->setContextProperty("vlcBackendAvailable", false);
    QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/BrowserJoystick.qml")));
    if (!component.isReady()) {
        if (errorString) *errorString = component.errorString();
        return nullptr;
    }
    QObject *object = component.create();
    if (!object) {
        if (errorString) *errorString = component.errorString();
        return nullptr;
    }
    auto *joystick = qobject_cast<QQuickItem *>(object);
    if (!joystick) return nullptr;
    joystick->setSize(size);
    joystick->setProperty("targetView", QVariant::fromValue(static_cast<QQuickItem *>(&fake)));
    return joystick;
}
