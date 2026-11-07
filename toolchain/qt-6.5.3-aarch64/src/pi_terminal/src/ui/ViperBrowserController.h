#pragma once

#include <QObject>
#include <QPointer>
#include <QVariantList>
#include <QNetworkCookie>
#include <QtWebEngineQuick/qquickwebengineprofile.h>
#include <QWebEngineUrlSchemeHandler>

class BookmarkManager;
class BrowserApplication;
class NetworkGate;
class ViperBrowserController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QQuickWebEngineProfile *profile READ profile NOTIFY profileReadyChanged)
    Q_PROPERTY(bool profileReady READ profileReady NOTIFY profileReadyChanged)
    Q_PROPERTY(int bookmarkCount READ bookmarkCount NOTIFY bookmarksChanged)
    Q_PROPERTY(bool javascriptPopupsEnabled READ javascriptPopupsEnabled NOTIFY browserSettingsChanged)
    Q_PROPERTY(QVariantMap preferences READ preferences NOTIFY browserSettingsChanged)
    Q_PROPERTY(QVariantList cookies READ cookies NOTIFY cookiesChanged)
    Q_PROPERTY(QVariantList subscriptions READ subscriptions NOTIFY subscriptionsChanged)
    Q_PROPERTY(QVariantList searchEngines READ searchEngines NOTIFY searchEnginesChanged)
    Q_PROPERTY(QString defaultSearchEngine READ defaultSearchEngine NOTIFY searchEnginesChanged)

public:
    explicit ViperBrowserController(QObject *parent = nullptr);
    ~ViperBrowserController() override;
    // 联网门控：宿主注入后，浏览器里**所有**请求都受总开关与「浏览器联网」约束。
    void setNetworkGate(NetworkGate *gate);
    QQuickWebEngineProfile *profile() const;

    // 访客隔离：把 WebEngine 的存储、缓存、下载目录切到会话专属的临时目录。
    // 退出时传 guest=false 恢复默认路径，并删除该访客目录。
    // 只切路径不换 profile：换 profile 会丢掉正在运行的页面与 cookie store 连接。
    Q_INVOKABLE void setGuestProfile(bool guest, const QString &guestId);
    bool profileReady() const;
    int bookmarkCount() const;

    Q_INVOKABLE QVariantList bookmarks() const;
    Q_INVOKABLE QString downloadDirectory() const;
    Q_INVOKABLE QString profileStoragePath() const;
    Q_INVOKABLE QString profileCachePath() const;
    Q_INVOKABLE bool attachProfile(QObject *profile);
    Q_INVOKABLE bool javascriptEnabled() const;
    Q_INVOKABLE bool javascriptPopupsEnabled() const;
    Q_INVOKABLE void setJavascriptPopupsEnabled(bool enabled);
    Q_INVOKABLE bool imagesEnabled() const;
    Q_INVOKABLE void recordVisit(const QUrl &url, const QString &title);
    Q_INVOKABLE QVariantList recentHistory() const;
    Q_INVOKABLE void clearHistory();
    Q_INVOKABLE void requestAdBlockData(const QUrl &url, int token);
    Q_INVOKABLE bool requestFilteringReady() const;
    Q_INVOKABLE bool customSchemesReady() const;
    Q_INVOKABLE bool isBookmarked(const QUrl &url) const;
    Q_INVOKABLE bool addBookmark(const QUrl &url, const QString &title);
    Q_INVOKABLE bool removeBookmark(const QUrl &url);
    QVariantMap preferences() const;
    Q_INVOKABLE bool setPreference(const QString &key, const QVariant &value);
    QVariantList cookies() const;
    Q_INVOKABLE bool setCookie(const QString &rawCookie, const QUrl &origin);
    Q_INVOKABLE void deleteCookie(int index);
    Q_INVOKABLE void clearCookies();
    Q_INVOKABLE void clearCache();
    QVariantList subscriptions() const;
    Q_INVOKABLE void installSubscription(const QUrl &url);
    Q_INVOKABLE void updateSubscriptions();
    Q_INVOKABLE void toggleSubscription(int row);
    Q_INVOKABLE void removeSubscription(int row);
    Q_INVOKABLE bool attachPrivateProfile(QObject *profile);
    Q_INVOKABLE QString newTabUrl() const;
    Q_INVOKABLE QString resolveAddress(const QString &text) const;
    Q_INVOKABLE QVariantMap savedSession() const;
    Q_INVOKABLE bool saveSession(const QVariantList &tabs, int currentIndex);
    QVariantList searchEngines() const;
    QString defaultSearchEngine() const;
    Q_INVOKABLE bool addSearchEngine(const QString &name, const QString &queryTemplate);
    Q_INVOKABLE void removeSearchEngine(const QString &name);
    Q_INVOKABLE void setDefaultSearchEngine(const QString &name);

signals:
    void profileReadyChanged();
    void bookmarksChanged();
    void adBlockDataReady(int token, const QString &css, const QString &script);
    void historyChanged();
    void browserSettingsChanged();
    void cookiesChanged();
    void subscriptionsChanged();
    void searchEnginesChanged();

private:
    void appendBookmarks(QVariantList &items, const class BookmarkNode *node) const;

    BrowserApplication *browser_ = nullptr;
    BookmarkManager *bookmarks_ = nullptr;
    NetworkGate *gate_ = nullptr;
    QList<QNetworkCookie> cookies_;
    QPointer<QQuickWebEngineProfile> privateProfile_;
    void configureProfile(QQuickWebEngineProfile *profile);
};
