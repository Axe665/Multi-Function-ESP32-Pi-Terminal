#pragma once
#include <QObject>
#include <QVariantMap>
#include <QProcess>
#include <QTimer>
#include <QSettings>

class IRController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap data READ data NOTIFY changed)
    Q_PROPERTY(QVariantMap placement READ placement NOTIFY placementChanged)
    Q_PROPERTY(bool online READ online NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool authenticated READ authenticated NOTIFY changed)
    Q_PROPERTY(bool demo READ demo CONSTANT)
    Q_PROPERTY(QString message READ message NOTIFY changed)
public:
    explicit IRController(bool demo, QObject *parent=nullptr);
    ~IRController() override;
    QVariantMap data() const { return m_data; }
    QVariantMap placement() const { return m_placement; }
    bool online() const { return m_online; }
    bool busy() const { return m_busy; }
    bool authenticated() const { return m_authenticated; }
    bool demo() const { return m_demo; }
    QString message() const { return m_message; }
    void start(const QString &python, const QString &worker, const QStringList &args);
    Q_INVOKABLE void setEnabled(bool enabled);
    Q_INVOKABLE void setRecording(bool enabled);
    // Trusted host integration only: invoke on terminal authentication changes.
    Q_INVOKABLE void setAuthenticatedUser(const QString &opaqueUserKey);
    Q_INVOKABLE void setPlacement(const QString &name, double x, double y, double angle, double length);
    Q_INVOKABLE void demoToggleBeam();
    Q_INVOKABLE void demoTogglePogo();
signals:
    void changed();
    void placementChanged();
private:
    void send(const QVariantMap &command);
    void readReplies();
    void useDeviceLayout(const QString &id);
    QProcess m_worker;
    QTimer m_stale;
    QSettings m_settings;
    QByteArray m_buffer;
    QVariantMap m_data, m_placement;
    bool m_demo=false, m_online=false, m_busy=false, m_authenticated=false;
    QString m_message, m_device;
};
