#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <notify.h>
#import <math.h>

static NSString *const RFDomain = @"com.minis.roothidefps";
static NSString *const RFChanged = @"RFPreferencesChanged";
static NSMutableDictionary *RFConfig;
static UIWindow *RFWindow;
// Shared within SpringBoard only. This is callback frequency, NOT hardware/App FPS.
double RFGlobalCallbackFPS = 0;

static BOOL RFLocked(void) {
    Class cls = NSClassFromString(@"SBLockScreenManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if ([cls respondsToSelector:shared]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
        for (NSString *name in @[@"isUILocked", @"isLocked"]) {
            SEL selector = NSSelectorFromString(name);
            if ([manager respondsToSelector:selector])
                return ((BOOL (*)(id, SEL))objc_msgSend)(manager, selector);
        }
    }
    static int stateToken = -1;
    if (stateToken == -1 && notify_register_check("com.apple.springboard.lockstate", &stateToken) != NOTIFY_STATUS_OK) {
        stateToken = -1; return YES;
    }
    uint64_t state = 0;
    if (notify_get_state(stateToken, &state) != NOTIFY_STATUS_OK) return YES;
    // Fallback requires on-device validation; never force visibility on lock screen.
    return state != 0;
}
static double RFValue(NSString *key) { return [RFConfig[key] doubleValue]; }
static void RFSave(void) {
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:RFConfig forName:RFDomain];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static void RFSet(NSString *key, double value) {
    RFConfig[key] = @(value);
    RFSave();
    [[NSNotificationCenter defaultCenter] postNotificationName:RFChanged object:nil];
}

@interface RFPassWindow : UIWindow
@end
@implementation RFPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface RFController : UIViewController
@property(nonatomic,strong) UILabel *label;
@property(nonatomic,strong) CADisplayLink *link;
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UIScrollView *scroll;
@property(nonatomic,strong) NSMutableDictionary<NSString *, UILabel *> *readouts;
@property(nonatomic,assign) CFTimeInterval start;
@property(nonatomic,assign) NSUInteger frames;
@property(nonatomic,assign) BOOL locked;
@property(nonatomic,assign) CGPoint dragStart;
- (void)applyConfig;
- (void)syncLock;
- (void)placeLabel;
- (void)updateColor;
- (void)togglePositionLock;
- (void)holdSettings:(UILongPressGestureRecognizer *)gesture;
- (void)openSettings;
- (void)closeSettings;
- (NSString *)titleForKey:(NSString *)key;
@end

@implementation RFController
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = UIColor.clearColor;
    self.label = [[UILabel alloc] initWithFrame:CGRectZero];
    self.label.text = @"FPS --";
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.backgroundColor = UIColor.clearColor;
    self.label.layer.cornerRadius = 0;
    self.label.clipsToBounds = YES;
    self.label.userInteractionEnabled = YES;
    self.label.accessibilityLabel = @"刷新回调频率，长按设置，双击锁定位置";
    [self.view addSubview:self.label];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [self.label addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePositionLock)];
    tap.numberOfTapsRequired = 2;
    [self.label addGestureRecognizer:tap];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(holdSettings:)];
    hold.minimumPressDuration = 0.6;
    [self.label addGestureRecognizer:hold];
    [pan requireGestureRecognizerToFail:hold];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyConfig) name:RFChanged object:nil];
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self applyConfig];
    [self syncLock];
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self placeLabel];
    if (self.panel) {
        UIEdgeInsets inset = self.view.safeAreaInsets;
        CGFloat w = MIN(340, self.view.bounds.size.width - inset.left - inset.right - 24);
        CGFloat h = MIN(510, self.view.bounds.size.height - inset.top - inset.bottom - 24);
        self.panel.frame = CGRectMake((self.view.bounds.size.width-w)/2, inset.top + (self.view.bounds.size.height-inset.top-inset.bottom-h)/2, w, h);
        self.scroll.frame = CGRectInset(self.panel.bounds, 12, 12);
        self.scroll.contentSize = CGSizeMake(w-24, 656);
        for (UIView *v in self.scroll.subviews) {
            CGRect f = v.frame; f.size.width = w-48; v.frame = f;
        }
    }
}
- (CGRect)movementRect {
    UIEdgeInsets insets = self.view.safeAreaInsets;
    return UIEdgeInsetsInsetRect(self.view.bounds, UIEdgeInsetsMake(4, insets.left+4, insets.bottom+4, insets.right+4));
}
- (void)placeLabel {
    CGRect region = [self movementRect];
    CGSize size = [@"FPS 120" sizeWithAttributes:@{NSFontAttributeName:self.label.font}];
    CGFloat w = MIN(region.size.width, ceil(size.width)+8);
    CGFloat h = ceil(size.height)+8;
    self.label.frame = CGRectMake(region.origin.x + MAX(0,region.size.width-w)*RFValue(@"x"), region.origin.y + MAX(0,region.size.height-h)*RFValue(@"y"), w, h);
}
- (void)applyConfig {
    self.label.font = [UIFont monospacedDigitSystemFontOfSize:RFValue(@"size") weight:UIFontWeightSemibold];
    [self updateColor];
    self.label.hidden = self.locked || ![RFConfig[@"enabled"] boolValue];
    self.link.paused = self.label.hidden;
    self.start = 0; self.frames = 0;
    if (@available(iOS 15.0, *)) {
        BOOL request = [RFConfig[@"request120"] boolValue];
        self.link.preferredFrameRateRange = request ? CAFrameRateRangeMake(30,120,120) : CAFrameRateRangeDefault;
    }
    [self placeLabel];
    for (NSString *key in self.readouts) {
        self.readouts[key].text = [self titleForKey:key];
    }
}
- (void)syncLock {
    self.locked = RFLocked();
    NSLog(@"[RootHideFPS 0.1.2] Window ready; locked=%d scene=%@", self.locked, RFWindow.windowScene);
    if (self.locked) [self closeSettings];
    RFWindow.hidden = self.locked;
    [self applyConfig];
}
- (void)tick:(CADisplayLink *)link {
    // Actual delivered callback count / actual monotonic elapsed time, not targetTimestamp.
    if (self.start == 0) { self.start = link.timestamp; return; }
    self.frames++;
    double elapsed = link.timestamp - self.start;
    if (elapsed >= 0.5) {
        RFGlobalCallbackFPS = self.frames / elapsed;
        self.label.text = [NSString stringWithFormat:@"FPS %.0f", RFGlobalCallbackFPS];
        [self updateColor];
        self.start = link.timestamp; self.frames = 0;
    }
}
- (void)holdSettings:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) [self openSettings];
}
- (void)togglePositionLock {
    RFSet(@"positionLocked", ![RFConfig[@"positionLocked"] boolValue]);
    self.label.accessibilityValue = [RFConfig[@"positionLocked"] boolValue] ? @"位置已锁定" : @"位置已解锁";
    // Brief visual acknowledgement without changing the reading or position.
    self.label.alpha = 0.45;
    [UIView animateWithDuration:0.25 animations:^{ self.label.alpha = 1; }];
}
- (void)updateColor {
    UIColor *color = [UIColor colorWithRed:RFValue(@"red") green:RFValue(@"green") blue:RFValue(@"blue") alpha:1];
    UIColor *outline = UIColor.clearColor;
    if ([RFConfig[@"autoColor"] boolValue]) {
        BOOL light = self.view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        // Optional private getter; absence falls back to appearance, not screen sampling.
        id manager = RFWindow.windowScene.statusBarManager;
        SEL getter = NSSelectorFromString(@"statusBar");
        if (![manager respondsToSelector:getter]) manager = UIApplication.sharedApplication;
        if ([manager respondsToSelector:getter]) {
            id bar = ((id (*)(id, SEL))objc_msgSend)(manager, getter);
            SEL foreground = NSSelectorFromString(@"foregroundColor");
            if ([bar respondsToSelector:foreground]) {
                id candidate = ((id (*)(id, SEL))objc_msgSend)(bar, foreground);
                if ([candidate isKindOfClass:UIColor.class]) {
                    CGFloat r=0,g=0,b=0,a=0,w=0;
                    UIColor *resolved = [(UIColor *)candidate resolvedColorWithTraitCollection:self.view.traitCollection];
                    if ([resolved getRed:&r green:&g blue:&b alpha:&a]) light = (0.2126*r+0.7152*g+0.0722*b)>0.5;
                    else if ([resolved getWhite:&w alpha:&a]) light = w>0.5;
                }
            }
        }
        color = light ? UIColor.whiteColor : UIColor.blackColor;
        outline = light ? UIColor.blackColor : UIColor.whiteColor;
    }
    self.label.textColor = color;
    NSString *text = self.label.text ?: @"FPS --";
    self.label.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSForegroundColorAttributeName:color,
        NSFontAttributeName:self.label.font,
        NSStrokeColorAttributeName:outline,
        NSStrokeWidthAttributeName:([RFConfig[@"autoColor"] boolValue] ? @(-2) : @0)
    }];
}
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if ([RFConfig[@"positionLocked"] boolValue]) return;
    if (gesture.state == UIGestureRecognizerStateBegan) self.dragStart = self.label.frame.origin;
    CGPoint delta = [gesture translationInView:self.view];
    CGRect region = [self movementRect];
    double dx = MAX(1, region.size.width-self.label.bounds.size.width);
    double dy = MAX(1, region.size.height-self.label.bounds.size.height);
    RFConfig[@"x"] = @(fmin(1,fmax(0,(self.dragStart.x+delta.x-region.origin.x)/dx)));
    RFConfig[@"y"] = @(fmin(1,fmax(0,(self.dragStart.y+delta.y-region.origin.y)/dy)));
    [self placeLabel];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) RFSave();
}
- (NSString *)titleForKey:(NSString *)key {
    NSDictionary *titles = @{@"size":@"字体大小", @"red":@"红色 R", @"green":@"绿色 G", @"blue":@"蓝色 B", @"x":@"水平位置", @"y":@"垂直位置"};
    return [NSString stringWithFormat:@"%@: %.0f%@", titles[key], RFValue(key)*([key isEqualToString:@"size"] ? 1 : 100), [key isEqualToString:@"size"] ? @" pt" : @"%"]; 
}
- (void)addText:(NSString *)text y:(CGFloat)y height:(CGFloat)height {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0,y,292,height)];
    label.text = text; label.textColor = UIColor.whiteColor; label.font = [UIFont systemFontOfSize:13]; label.numberOfLines = 0;
    [self.scroll addSubview:label];
}
- (void)addSwitch:(NSString *)title key:(NSString *)key y:(CGFloat)y {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0,y,292,36);
    button.accessibilityIdentifier = key;
    [button setTitle:[NSString stringWithFormat:@"%@：%@", title, [RFConfig[key] boolValue] ? @"开" : @"关"] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:button];
}
- (void)toggle:(UIButton *)button {
    NSString *key = button.accessibilityIdentifier;
    RFSet(key, ![RFConfig[key] boolValue]);
    NSString *title = [key isEqualToString:@"autoColor"] ? @"自动黑白（跟随状态栏）" : @"请求高刷新率（耗电）";
    [button setTitle:[NSString stringWithFormat:@"%@：%@",title,[RFConfig[key] boolValue] ? @"开" : @"关"] forState:UIControlStateNormal];
}
- (void)sliderChanged:(UISlider *)slider { RFSet(slider.accessibilityIdentifier, slider.value); }
- (void)openSettings {
    if (self.panel || self.locked) return;
    self.panel = [[UIView alloc] initWithFrame:CGRectZero];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    self.panel.layer.cornerRadius = 18;
    [self.view addSubview:self.panel];
    self.scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [self.panel addSubview:self.scroll];
    self.readouts = [NSMutableDictionary dictionary];
    [self addText:@"RootHide FPS · 长按设置／双击锁定" y:0 height:30];
    [self addText:@"FPS 数字来自 SpringBoard 回调统计，不是硬件／游戏真实 FPS。双击锁定或解锁位置；解锁后可拖动。状态栏区域定位可能与系统控件重叠。" y:30 height:64];
    NSArray *keys = @[@"size",@"red",@"green",@"blue",@"x",@"y"];
    CGFloat y = 100;
    for (NSString *key in keys) {
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0,y,292,22)];
        title.textColor = UIColor.whiteColor; title.font = [UIFont systemFontOfSize:14];
        title.text = [self titleForKey:key]; self.readouts[key] = title;
        [self.scroll addSubview:title];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0,y+22,292,28)];
        slider.minimumValue = [key isEqualToString:@"size"] ? 10 : 0;
        slider.maximumValue = [key isEqualToString:@"size"] ? 48 : 1;
        slider.value = RFValue(key); slider.accessibilityIdentifier = key;
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.scroll addSubview:slider]; y += 56;
    }
    [self addSwitch:@"自动黑白（跟随状态栏）" key:@"autoColor" y:440];
    [self addSwitch:@"请求高刷新率（耗电）" key:@"request120" y:476];
    [self addText:@"自动颜色尝试读取系统状态栏文字颜色，失败则用系统样式＋对比描边；不截屏采样，不能保证随局部背景反色。关闭自动颜色使用 RGB 自定义颜色。" y:516 height:90];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(0,612,292,36); [close setTitle:@"完成" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:close];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
}
- (void)closeSettings {
    [self.panel removeFromSuperview]; self.panel = nil; self.scroll = nil; self.readouts = nil;
}
@end

static RFController *RFOverlay;
static void RFStart(void) {
    if (RFWindow) return;
    RFConfig = [@{@"size":@12, @"red":@0.2, @"green":@1, @"blue":@0.4, @"x":@0.95, @"y":@0.045, @"enabled":@YES, @"request120":@NO, @"positionLocked":@YES, @"autoColor":@YES} mutableCopy];
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] persistentDomainForName:RFDomain];
    for (NSString *key in RFConfig.allKeys) {
        id value = saved[key];
        if ([value isKindOfClass:NSNumber.class]) RFConfig[key] = value;
    }
    for (NSString *key in @[@"red",@"green",@"blue",@"x",@"y"]) RFConfig[key] = @(fmin(1,fmax(0,RFValue(key))));
    RFConfig[@"size"] = @(fmin(48,fmax(10,RFValue(@"size"))));
    if (![saved[@"styleVersion"] isEqual:@2]) {
        RFConfig[@"size"] = @12; RFConfig[@"x"] = @0.94; RFConfig[@"y"] = @0.045;
        RFConfig[@"positionLocked"] = @YES; RFConfig[@"autoColor"] = @YES;
        RFConfig[@"styleVersion"] = @2;
        RFSave();
    }
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class]) {
            scene = (UIWindowScene *)candidate;
            if (candidate.activationState == UISceneActivationStateForegroundActive) break;
        }
    }
    if (!scene) {
        NSLog(@"[RootHideFPS 0.1.2] No UIWindowScene yet; waiting for scene activation");
        return;
    }
    RFWindow = [[RFPassWindow alloc] initWithWindowScene:scene];
    RFWindow.frame = scene.coordinateSpace.bounds;
    RFWindow.windowLevel = UIWindowLevelAlert + 100;
    RFWindow.backgroundColor = UIColor.clearColor;
    RFOverlay = [RFController new];
    RFWindow.rootViewController = RFOverlay;
    // Do not makeKeyAndVisible: never steal keyboard focus from SpringBoard.
    RFWindow.hidden = NO;
    (void)RFOverlay.view;
    [RFOverlay syncLock];
    static int lockToken;
    notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) { [RFOverlay syncLock]; });
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [RFOverlay syncLock]; }];
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ RFStart(); });
}
%end

%ctor {
    %init;
    NSLog(@"[RootHideFPS 0.1.2] Dylib loaded");
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *name in @[UIApplicationDidFinishLaunchingNotification, UISceneDidActivateNotification]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                RFStart();
                if (RFOverlay) [RFOverlay syncLock];
            }];
        }
        // Bounded retries cover injection after the launch callback has already run.
        for (int attempt = 1; attempt <= 5; attempt++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attempt * 2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                RFStart();
            });
        }
    });
}

