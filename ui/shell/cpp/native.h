// LughNative: the few native calls QML cannot make itself. Exposed to QML as
// the context property `LughNative` (see ui/shell/README.md, "Gaps").
#pragma once

#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QVariantList>
#include <QtGui/QGuiApplication>
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
        // Platforms without window masks (offscreen, used by --check) only warn.
        if (!window || QGuiApplication::platformName() == QLatin1String("offscreen"))
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
            m_hasIcon.clear();
            Q_EMIT iconThemeChanged();
        }
        return QIcon::themeName();
    }
    // Whether the current icon theme (or its fallbacks) has `name`. Cached:
    // the dock and the launcher ask for the same names again and again.
    Q_INVOKABLE bool hasThemeIcon(const QString &name)
    {
        if (name.isEmpty())
            return false;
        const auto it = m_hasIcon.constFind(name);
        if (it != m_hasIcon.constEnd())
            return it.value();
        const bool has = QIcon::hasThemeIcon(name);
        m_hasIcon.insert(name, has);
        return has;
    }
    Q_INVOKABLE QString iconThemeName() const { return QIcon::themeName(); }
    Q_INVOKABLE QString qtVersion() const { return QString::fromLatin1(qVersion()); }

    // True when `<theme search path>/<name>/index.theme` exists.
    static bool isIconThemeInstalled(const QString &name);

Q_SIGNALS:
    void iconThemeChanged();

private:
    QHash<QString, bool> m_hasIcon; // GUI thread only; cleared on theme change
};
