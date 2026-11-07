#include <QtTest>

#include <QTemporaryDir>

#include "app/OnboardingController.h"
#include "security/RecoveryCode.h"
#include "security/UserService.h"

// 首次开机向导的服务端契约测试。
//
// 不加载 QML：OOBE 的步骤编排在 QML，但“什么时候需要向导 / 恢复码是
// 否正确 / 创建是否成功 / 是否落盘”全在这里，可以纯 C++ 验证。
// 登录路径用 session=nullptr 跳过——真实登录由 auth_service_test 覆盖，
// 这里只断言“创建后立刻 ready”，避免测试环境依赖 SQLCipher 库文件。
class OnboardingTest : public QObject {
    Q_OBJECT

private slots:
    void emptyRegistryRequiresOnboarding();
    void recoveryCodeIsStableAndGrouped();
    void confirmRecoveryRejectsMismatch();
    void createAdminRejectsInvalidInput();
    void createAdminCreatesUserAndFinishes();
    void rearmRestartsWizardFromScratch();

private:
    QTemporaryDir dir_;
};

void OnboardingTest::emptyRegistryRequiresOnboarding()
{
    security::UserService users(dir_.filePath(QStringLiteral("users.json")));
    QVERIFY(!users.hasAnyUser());

    OnboardingController controller(users, nullptr, false);
    QVERIFY(!controller.active());
    controller.setStartupRequirement(true);
    QVERIFY(controller.active());
    // 未完成创建前 dismiss 必须无效：没有任何用户时不能关掉向导。
    controller.dismiss();
    QVERIFY(controller.active());

    // 已有用户时调用方会传 false；重复设置必须幂等。
    controller.setStartupRequirement(false);
    QVERIFY(!controller.active());
}

void OnboardingTest::recoveryCodeIsStableAndGrouped()
{
    security::UserService users(dir_.filePath(QStringLiteral("users.json")));
    OnboardingController controller(users, nullptr, false);
    controller.setStartupRequirement(true);

    controller.prepareRecoveryCode();
    const QString first = controller.recoveryCode();
    QVERIFY(!first.isEmpty());

    // 幂等：返回上一步再回来不能换一个新码，否则用户抄下的作废。
    controller.prepareRecoveryCode();
    QCOMPARE(controller.recoveryCode(), first);

    QCOMPARE(security::RecoveryCode::normalize(first).size(), security::RecoveryCode::kChars);
    QVERIFY(security::RecoveryCode::isValidFormat(first));

    // 6 组、每组 4 字符，且拼起来等于规范化后的整码。
    QString joined;
    for (int i = 0; i < security::RecoveryCode::kGroups; ++i) {
        const QString group = controller.recoveryGroup(i);
        QCOMPARE(group.size(), security::RecoveryCode::kGroupSize);
        joined += group;
    }
    QCOMPARE(joined, security::RecoveryCode::normalize(first));
    QVERIFY(controller.recoveryGroup(-1).isEmpty());
    QVERIFY(controller.recoveryGroup(security::RecoveryCode::kGroups).isEmpty());
}

void OnboardingTest::confirmRecoveryRejectsMismatch()
{
    security::UserService users(dir_.filePath(QStringLiteral("users.json")));
    OnboardingController controller(users, nullptr, false);
    controller.setStartupRequirement(true);
    controller.prepareRecoveryCode();

    const QString group2 = controller.recoveryGroup(1);
    const QString group5 = controller.recoveryGroup(4);

    // 故意给错误值：不能通过，且错误码要能被 QML 映射成文案。
    QVERIFY(!controller.confirmRecovery(QStringLiteral("AAAA"), QStringLiteral("BBBB")));
    QCOMPARE(controller.errorCode(), QStringLiteral("recovery_mismatch"));

    // 大小写/空格/连字符由 normalize 处理。
    QVERIFY(controller.confirmRecovery(group2.toLower() + QStringLiteral(" "), group5));
    QVERIFY(controller.errorCode().isEmpty());
}

void OnboardingTest::createAdminRejectsInvalidInput()
{
    security::UserService users(dir_.filePath(QStringLiteral("users.json")));
    OnboardingController controller(users, nullptr, false);
    controller.setStartupRequirement(true);
    controller.prepareRecoveryCode();

    controller.createAdmin(QStringLiteral("x"), QStringLiteral("123456"), QStringLiteral("123456"));
    QCOMPARE(controller.errorCode(), QStringLiteral("name_invalid"));

    controller.createAdmin(QStringLiteral("测试管理员"), QStringLiteral("123456"),
                           QStringLiteral("654321"));
    QCOMPARE(controller.errorCode(), QStringLiteral("pin_mismatch"));

    controller.createAdmin(QStringLiteral("测试管理员"), QStringLiteral("12345"),
                           QStringLiteral("12345"));
    QCOMPARE(controller.errorCode(), QStringLiteral("pin_invalid"));

    // 以上都在写盘前被拒绝。
    QVERIFY(!users.hasAnyUser());
    QVERIFY(!controller.ready());
}

void OnboardingTest::createAdminCreatesUserAndFinishes()
{
    security::UserService users(dir_.filePath(QStringLiteral("users.json")));
    OnboardingController controller(users, nullptr, false);
    controller.setStartupRequirement(true);
    controller.prepareRecoveryCode();

    QSignalSpy finished(&controller, &OnboardingController::finished);
    controller.createAdmin(QStringLiteral("测试管理员"), QStringLiteral("123456"),
                           QStringLiteral("123456"));

    // createAdmin 是异步的（先让 QML 画出 busy，再跑 600k 次 PBKDF2）。
    QVERIFY(finished.wait(10000));
    QCOMPARE(finished.count(), 1);
    QCOMPARE(finished.first().at(0).toBool(), true);
    QVERIFY(controller.ready());
    QVERIFY(users.hasAnyUser());

    // 创建成功后再次调用必须是 no-op，不能覆盖已有注册表。
    controller.createAdmin(QStringLiteral("第二个"), QStringLiteral("123456"),
                           QStringLiteral("123456"));
    QVERIFY(controller.errorCode().isEmpty());
    QCOMPARE(finished.count(), 1);

    // dismiss 只在 ready 后生效。
    controller.dismiss();
    QVERIFY(!controller.active());
}

// 最后一名用户（可能也是最后一名管理员）自删后，宿主调 rearm() 把向导
// 重新拉起来。新一轮必须从第一步开始：ready 复位、恢复码重新生成，
// 否则 QML 会停在“已完成”或沿用上一轮已经展示过的旧码。
void OnboardingTest::rearmRestartsWizardFromScratch()
{
    // 独立临时目录：createInitialAdmin 只在注册表为空时成功，
    // 不能沿用共享 dir_ 里其它用例已经建好的用户。
    QTemporaryDir local;
    QVERIFY(local.isValid());
    security::UserService users(local.filePath(QStringLiteral("users.json")));
    OnboardingController controller(users, nullptr, false);
    controller.setStartupRequirement(true);
    controller.prepareRecoveryCode();
    const QString firstCode = controller.recoveryCode();
    QVERIFY(!firstCode.isEmpty());

    QSignalSpy finished(&controller, &OnboardingController::finished);
    controller.createAdmin(QStringLiteral("测试管理员"), QStringLiteral("123456"),
                           QStringLiteral("123456"));
    QVERIFY(finished.wait(10000));
    QVERIFY(controller.ready());
    controller.dismiss();
    QVERIFY(!controller.active());
    QVERIFY(!controller.recoveryCode().isEmpty());

    // 注册表被删空的判定在宿主（hasAnyUser），这里只验证 rearm 的状态复位。
    controller.rearm();
    QVERIFY(controller.active());
    QVERIFY(!controller.ready());
    QVERIFY(!controller.busy());
    QVERIFY(controller.errorCode().isEmpty());
    QVERIFY(controller.recoveryCode().isEmpty());

    // 新一轮必须换一份新码：旧码已经被抄过，再展示一次会让用户以为还生效。
    controller.prepareRecoveryCode();
    QVERIFY(!controller.recoveryCode().isEmpty());
    QVERIFY(controller.recoveryCode() != firstCode);

    // 已经在向导里时再调 rearm 是 no-op，不能把新一轮的恢复码又清掉。
    controller.rearm();
    QVERIFY(controller.active());
    QVERIFY(!controller.recoveryCode().isEmpty());
}

QTEST_GUILESS_MAIN(OnboardingTest)
#include "onboarding_test.moc"
