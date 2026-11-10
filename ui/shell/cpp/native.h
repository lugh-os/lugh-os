// LughNative: the few native calls QML cannot make itself. Exposed to QML as
// the context property `LughNative` (see ui/shell/README.md, "Gaps").
#pragma once

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QVariantList>
#include <QtGui/QIcon>
#include <QtGui/QRegion>
#include <QtQuick/QQuickWindow>

class LughNative : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;

    // Input region of a window: the union of `rects` (QML rects, window
    // coordinates). An empty list clears the mask (the whole window takes
    // input again). On Wayland QWindow::setMask is the surface's input region.
    Q_INVOKABLE void setInputRegion(QQuickWindow *window, const QVariantList &rects)
    {
        if (!window)
            return;
        QRegion region;
        for (const QVariant &v : rects) {
            const QRect r = v.toRectF().toAlignedRect();
            if (r.isValid())
                region += r;
        }
        if (region != window->mask())
            window->setMask(region);
    }

    // Switches the icon theme at run time when it is installed; returns the
    // theme now in use.
    Q_INVOKABLE QString setIconTheme(const QString &name)
    {
        if (name != QIcon::themeName() && isIconThemeInstalled(name)) {
            QIcon::setThemeName(name);
            Q_EMIT iconThemeChanged();
        }
        return QIcon::themeName();
    }
    Q_INVOKABLE QString iconThemeName() const { return QIcon::themeName(); }
    Q_INVOKABLE QString qtVersion() const { return QString::fromLatin1(qVersion()); }

    // True when `<theme search path>/<name>/index.theme` exists.
    static bool isIconThemeInstalled(const QString &name);

Q_SIGNALS:
    void iconThemeChanged();
};
