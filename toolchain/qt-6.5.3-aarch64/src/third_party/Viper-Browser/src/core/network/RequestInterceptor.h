#ifndef REQUESTINTERCEPTOR_H
#define REQUESTINTERCEPTOR_H

#include "ServiceLocator.h"
#include "Settings.h"
#include "ISettingsObserver.h"

#include <memory>
#include <QByteArray>
#include <QWebEngineUrlRequestInterceptor>

namespace adblock {
    class AdBlockManager;
}

class WebPage;

/**
 * @class RequestInterceptor 
 * @brief Intercepts network requests before they are made, checking if they need special handlnig.
 */
class RequestInterceptor : public QWebEngineUrlRequestInterceptor, public ISettingsObserver
{
    Q_OBJECT

public:
    /// Constructs the request interceptor with an optional parent pointer
    RequestInterceptor(const ViperServiceLocator &serviceLocator, QObject *parent = nullptr);

    /// Host-wide kill switch: while blocked, EVERY request is cancelled (including the
    /// main document), so a browser window opened before the switch was turned off
    /// cannot keep loading anything. Thread-safe: the value is read from the IO thread.
    /// 宿主总闸：置位后拦截**全部**请求（含主文档）。实现用 atomic，IO 线程安全。
    static void setNetworkBlocked(bool blocked);

protected:
    /// Intercepts the given request, potentially blocking it, modifying the header values or redirecting the request
    void interceptRequest(QWebEngineUrlRequestInfo &info) override;

private:
    /// Attempts to fetch the settings and adblock manager services
    void fetchServices();

private Q_SLOTS:
    /// Listens for any settings changes that affect the request interceptor (currently just the "do not track" header setting)
    void onSettingChanged(BrowserSetting setting, const QVariant &value) override;

private:
    /// Service locator
    const ViperServiceLocator &m_serviceLocator;

    /// Advertisement blocking system manager
    adblock::AdBlockManager *m_adBlockManager;

    /// Parent web page. Only used with QtWebEngine version 5.13 or greater.
    WebPage *m_parentPage;

    /// Flag indicating whether or not to send the "Do not track" (DNT) header with requests
    bool m_sendDoNotTrack;

    /// Flag indicating whether or not to send a custom user agent in network requests
    bool m_sendCustomUserAgent;

    /// Custom user agent (Qt does not send the custom user agent in many types of requests. We have to override when enabled by the user)
    QByteArray m_userAgent;
};

#endif // REQUESTINTERCEPTOR_H 
