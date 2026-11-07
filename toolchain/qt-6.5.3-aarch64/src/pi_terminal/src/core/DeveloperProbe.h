#pragma once

#include <QObject>
#include <QVariantList>
#include <QString>

// 开发者面板的宿主探针：只提供 QML 拿不到的东西
// （构建/运行环境、模块缓存目录、剪贴板、快照导出）。
// 业务状态仍由现有 QML 对象读取，本类不重复持有。
class DeveloperProbe : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString runtimeJson READ runtimeJson CONSTANT)
public:
    explicit DeveloperProbe(QObject *parent = nullptr);

    QString runtimeJson() const;

    // 模块安装根目录下的条目（内容寻址目录 / 文件），原样返回。
    Q_INVOKABLE QVariantList moduleCache(const QString &root) const;

    Q_INVOKABLE bool copyText(const QString &text) const;

    // 写一份快照文本，返回绝对路径；失败返回 "ERROR: ..."。
    Q_INVOKABLE QString exportText(const QString &content) const;
};
