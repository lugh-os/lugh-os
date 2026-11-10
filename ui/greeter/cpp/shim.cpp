#include "shim.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QEvent>
#include <QtCore/QString>
#include <QtCore/QTimer>
#include <QtCore/QUrl>
#include <QtGui/QGuiApplication>
#include <QtGui/QIcon>
#include <QtGui/QKeyEvent>
#include <QtQml/QQmlApplicationEngine>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlContext>
#include <QtQml/QQmlError>

namespace lugh {

namespace {

// Where cxx-qt-build puts the adapter inside the `os.lugh.greeter` module.
const char* const ADAPTER_URL = "qrc:/qt/qml/os/lugh/greeter/qml/backend/GreetdBackend.qml";

QString toQString(rust::Str text)
{
    return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
}

// Qt has no Caps Lock query on Wayland, so this follows the key events of the
// window: the Caps Lock key toggles the flag, and every other key corrects it
// from the native (xkb) modifier mask, where Lock is bit 1.
class CapsLockWatcher : public QObject {
public:
    explicit CapsLockWatcher(QObject* backend)
        : QObject(backend)
        , m_backend(backend)
    {
    }

protected:
    bool eventFilter(QObject* watched, QEvent* event) override
    {
        const bool press = event->type() == QEvent::KeyPress;
        if ((press || event->type() == QEvent::KeyRelease) && watched->isWindowType()) {
            const auto* key = static_cast<QKeyEvent*>(event);
            bool caps = m_caps;
            if (key->key() == Qt::Key_CapsLock) {
                if (press && !key->isAutoRepeat())
                    caps = !caps;
            } else if (m_native || key->nativeModifiers() != 0) {
                // Only trust the mask on platforms that fill it in.
                m_native = true;
                caps = (key->nativeModifiers() & 0x2U) != 0;
            }
            if (caps != m_caps) {
                m_caps = caps;
                m_backend->setProperty("capsLock", caps);
            }
        }
        return false;
    }

private:
    QObject* m_backend;
    bool m_caps = false;
    bool m_native = false;
};

} // namespace

std::int32_t greeter_run(rust::Str qml_dir, rust::Str import_path, bool offscreen, bool check)
{
    if (offscreen)
        qputenv("QT_QPA_PLATFORM", "offscreen");

    static int argc = 1;
    static char name[] = "lugh-greeter";
    static char* argv[] = { name, nullptr };
    QGuiApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("lugh-greeter"));
    QCoreApplication::setOrganizationName(QStringLiteral("Lugh"));
    QGuiApplication::setDesktopFileName(QStringLiteral("lugh-greeter"));
    // The greeter user has no platform theme: name the icon theme ourselves.
    if (QIcon::themeName().isEmpty() || QIcon::themeName() == QLatin1String("hicolor"))
        QIcon::setThemeName(QStringLiteral("Lugh"));
    QIcon::setFallbackThemeName(QStringLiteral("hicolor"));

    QQmlApplicationEngine engine;
    engine.addImportPath(toQString(import_path));

    int problems = 0;
    QObject::connect(&engine, &QQmlEngine::warnings, &app, [&problems](const QList<QQmlError>& warnings) {
        problems += static_cast<int>(warnings.size());
    });

    QQmlComponent adapter(&engine, QUrl(QString::fromLatin1(ADAPTER_URL)));
    QObject* backend = adapter.create();
    if (backend == nullptr) {
        qCritical().noquote() << "lugh-greeter: cannot create the backend:" << adapter.errorString();
        return 1;
    }
    backend->setParent(&engine);
    engine.rootContext()->setContextProperty(QStringLiteral("greetdBackend"), backend);
    app.installEventFilter(new CapsLockWatcher(backend));

    const QString main = QDir(toQString(qml_dir)).absoluteFilePath(QStringLiteral("main.qml"));
    engine.load(QUrl::fromLocalFile(main));
    if (engine.rootObjects().isEmpty()) {
        qCritical().noquote() << "lugh-greeter: cannot load" << main;
        return 1;
    }

    if (check) {
        // Give bindings, loaders and the first frame a moment to complain.
        QTimer::singleShot(500, &app, [&problems] { QCoreApplication::exit(problems == 0 ? 0 : 1); });
    }
    return QCoreApplication::exec();
}

void greeter_quit(std::int32_t code)
{
    QCoreApplication::exit(code);
}

} // namespace lugh
