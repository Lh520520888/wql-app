#import "WQLVpnViewController.h"
#import "WQLLog.h"
#import <QuartzCore/QuartzCore.h>
#include <stdlib.h>
#include <math.h>

typedef NS_ENUM(NSInteger, WQLVpnState) {
    WQLVpnStateIdle = 0,
    WQLVpnStateConnecting,
    WQLVpnStateConnected,
};

static UIColor *WQLRGB(uint32_t v) {
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0
                           alpha:1.0];
}

static UIColor *WQLRGBA(uint32_t v, CGFloat a) {
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0
                           alpha:a];
}

#pragma mark - 线路模型

@interface WQLVpnServer : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *region;
@property (nonatomic, copy) NSString *ip;
@property (nonatomic, assign) NSInteger latency;
@property (nonatomic, assign) NSInteger load;
@end

@implementation WQLVpnServer
@end

#pragma mark - 线路行

@interface WQLVpnServerRow : UIControl
@property (nonatomic, strong) WQLVpnServer *server;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *codeLabel;
@property (nonatomic, strong) UILabel *latencyLabel;
@property (nonatomic, strong) UIView *loadTrack;
@property (nonatomic, strong) UIView *loadFill;
@property (nonatomic, strong) UIView *checkDot;
- (void)setSelectedStyle:(BOOL)selected;
@end

@implementation WQLVpnServerRow {
    UIView *_bg;
}

- (instancetype)initWithServer:(WQLVpnServer *)server {
    if (self = [super initWithFrame:CGRectZero]) {
        _server = server;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _bg = [UIView new];
        _bg.translatesAutoresizingMaskIntoConstraints = NO;
        _bg.backgroundColor = WQLRGBA(0xFFFFFF, 0.04);
        _bg.layer.cornerRadius = 14;
        _bg.layer.borderWidth = 1;
        _bg.layer.borderColor = WQLRGBA(0xFFFFFF, 0.06).CGColor;
        _bg.userInteractionEnabled = NO;
        [self addSubview:_bg];

        _nameLabel = [UILabel new];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.text = server.name;
        _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _nameLabel.textColor = WQLRGB(0xF2F5FB);
        [self addSubview:_nameLabel];

        _codeLabel = [UILabel new];
        _codeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _codeLabel.text = [NSString stringWithFormat:@"%@ · %@", server.code, server.region];
        _codeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _codeLabel.textColor = WQLRGB(0x6B7793);
        [self addSubview:_codeLabel];

        _latencyLabel = [UILabel new];
        _latencyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _latencyLabel.text = [NSString stringWithFormat:@"%ld ms", (long)server.latency];
        _latencyLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        _latencyLabel.textColor = server.latency < 60 ? WQLRGB(0x2EE6A8) : WQLRGB(0x8FA0BD);
        _latencyLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_latencyLabel];

        _loadTrack = [UIView new];
        _loadTrack.translatesAutoresizingMaskIntoConstraints = NO;
        _loadTrack.backgroundColor = WQLRGBA(0xFFFFFF, 0.07);
        _loadTrack.layer.cornerRadius = 2;
        [self addSubview:_loadTrack];

        _loadFill = [UIView new];
        _loadFill.translatesAutoresizingMaskIntoConstraints = NO;
        _loadFill.backgroundColor = server.load > 70 ? WQLRGB(0xFF9F43) : WQLRGB(0x38E8FF);
        _loadFill.layer.cornerRadius = 2;
        [_loadTrack addSubview:_loadFill];

        _checkDot = [UIView new];
        _checkDot.translatesAutoresizingMaskIntoConstraints = NO;
        _checkDot.layer.cornerRadius = 5;
        _checkDot.layer.borderWidth = 1.5;
        _checkDot.layer.borderColor = WQLRGBA(0xFFFFFF, 0.22).CGColor;
        [self addSubview:_checkDot];

        [NSLayoutConstraint activateConstraints:@[
            [_bg.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_bg.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_bg.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_bg.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_checkDot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [_checkDot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_checkDot.widthAnchor constraintEqualToConstant:10],
            [_checkDot.heightAnchor constraintEqualToConstant:10],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_checkDot.trailingAnchor constant:12],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:13],

            [_codeLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_codeLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_codeLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-13],

            [_latencyLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
            [_latencyLabel.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
            [_latencyLabel.widthAnchor constraintEqualToConstant:58],

            [_loadTrack.trailingAnchor constraintEqualToAnchor:_latencyLabel.trailingAnchor],
            [_loadTrack.topAnchor constraintEqualToAnchor:_latencyLabel.bottomAnchor constant:5],
            [_loadTrack.widthAnchor constraintEqualToConstant:58],
            [_loadTrack.heightAnchor constraintEqualToConstant:4],

            [_loadFill.leadingAnchor constraintEqualToAnchor:_loadTrack.leadingAnchor],
            [_loadFill.topAnchor constraintEqualToAnchor:_loadTrack.topAnchor],
            [_loadFill.bottomAnchor constraintEqualToAnchor:_loadTrack.bottomAnchor],
            [_loadFill.widthAnchor constraintEqualToAnchor:_loadTrack.widthAnchor
                                              multiplier:MAX(6, MIN(100, server.load)) / 100.0],
        ]];
    }
    return self;
}

- (void)setSelectedStyle:(BOOL)selected {
    _bg.backgroundColor = selected ? WQLRGBA(0x3B7BFF, 0.16) : WQLRGBA(0xFFFFFF, 0.04);
    _bg.layer.borderColor = (selected ? WQLRGBA(0x3B7BFF, 0.55) : WQLRGBA(0xFFFFFF, 0.06)).CGColor;
    _checkDot.layer.borderColor = (selected ? WQLRGB(0x38E8FF) : WQLRGBA(0xFFFFFF, 0.22)).CGColor;
    _checkDot.backgroundColor = selected ? WQLRGB(0x38E8FF) : [UIColor clearColor];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.7 : 1.0;
}

@end

#pragma mark - 主界面

@interface WQLVpnViewController ()
@property (nonatomic, assign) WQLVpnState state;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) CAGradientLayer *bgLayer;

@property (nonatomic, strong) UIView *ringHost;
@property (nonatomic, strong) CAShapeLayer *trackLayer;
@property (nonatomic, strong) CAShapeLayer *progressLayer;
@property (nonatomic, strong) UIButton *powerButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *subStatusLabel;

@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UILabel *downLabel;
@property (nonatomic, strong) UILabel *upLabel;
@property (nonatomic, strong) UILabel *ipLabel;

@property (nonatomic, strong) NSMutableArray<WQLVpnServerRow *> *rows;
@property (nonatomic, strong) NSArray<WQLVpnServer *> *servers;
@property (nonatomic, strong) WQLVpnServer *current;

@property (nonatomic, strong) NSTimer *ticker;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, assign) double downBytes;
@property (nonatomic, assign) double upBytes;
@property (nonatomic, assign) NSInteger seconds;
@end

@implementation WQLVpnViewController

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = WQLRGB(0x05070F);
    self.state = WQLVpnStateIdle;

    [self buildServers];
    [self buildBackground];
    [self buildContent];
    [self refreshUI];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [(UIScrollView *)self.scroll flashScrollIndicators];
}

- (void)dealloc {
    [_ticker invalidate];
}

#pragma mark - 数据

- (void)buildServers {
    NSArray *defs = @[
        @[@"香港", @"HK-01", @"亚太 · 港岛", @"103.42.18.77",  @18,  @24],
        @[@"日本", @"JP-03", @"亚太 · 东京", @"45.76.101.204", @32,  @41],
        @[@"新加坡", @"SG-02", @"亚太 · 狮城", @"128.199.76.15", @46, @33],
        @[@"美国", @"US-07", @"北美 · 洛杉矶", @"104.28.9.132", @128, @62],
        @[@"德国", @"DE-04", @"欧洲 · 法兰克福", @"85.10.201.88", @176, @47],
        @[@"英国", @"UK-01", @"欧洲 · 伦敦", @"178.62.44.19", @192, @55],
    ];
    NSMutableArray *list = [NSMutableArray array];
    for (NSArray *d in defs) {
        WQLVpnServer *s = [WQLVpnServer new];
        s.name = d[0];
        s.code = d[1];
        s.region = d[2];
        s.ip = d[3];
        s.latency = [d[4] integerValue];
        s.load = [d[5] integerValue];
        [list addObject:s];
    }
    self.servers = list;
    self.current = list.firstObject;
}

#pragma mark - 背景

- (void)buildBackground {
    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.colors = @[(id)WQLRGB(0x070C1A).CGColor,
                  (id)WQLRGB(0x0B1430).CGColor,
                  (id)WQLRGB(0x05070F).CGColor];
    bg.locations = @[@0.0, @0.45, @1.0];
    bg.startPoint = CGPointMake(0.1, 0.0);
    bg.endPoint = CGPointMake(0.9, 1.0);
    [self.view.layer insertSublayer:bg atIndex:0];
    self.bgLayer = bg;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.bgLayer.frame = self.view.bounds;
    [self layoutRing];
}

#pragma mark - 界面

- (void)buildContent {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];
    self.scroll = scroll;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIView *content = [UIView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
    ]];

    // ---- 顶部品牌栏 ----
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon1024" ofType:@"png"];
    UIImage *iconImg = iconPath ? [UIImage imageWithContentsOfFile:iconPath] : nil;
    UIImageView *logo = [[UIImageView alloc] initWithImage:iconImg];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.layer.cornerRadius = 10;
    logo.clipsToBounds = YES;
    logo.contentMode = UIViewContentModeScaleAspectFill;
    logo.backgroundColor = WQLRGB(0x0B1430);
    [content addSubview:logo];

    UILabel *brand = [UILabel new];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    brand.text = @"北极星 VPN";
    brand.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    brand.textColor = WQLRGB(0xF2F5FB);
    [content addSubview:brand];

    UILabel *brandSub = [UILabel new];
    brandSub.translatesAutoresizingMaskIntoConstraints = NO;
    brandSub.text = @"POLARIS VPN";
    brandSub.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    brandSub.textColor = WQLRGBA(0x38E8FF, 0.75);
    brandSub.attributedText = [[NSAttributedString alloc]
        initWithString:@"POLARIS VPN"
            attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: WQLRGBA(0x38E8FF, 0.75),
                NSKernAttributeName: @2.0
            }];
    [content addSubview:brandSub];

    UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
    gear.translatesAutoresizingMaskIntoConstraints = NO;
    [gear setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    gear.tintColor = WQLRGBA(0xFFFFFF, 0.55);
    [gear addTarget:self action:@selector(onSettings) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:gear];

    // ---- 连接环 ----
    UIView *ringHost = [UIView new];
    ringHost.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:ringHost];
    self.ringHost = ringHost;

    UIButton *power = [UIButton buttonWithType:UIButtonTypeSystem];
    power.translatesAutoresizingMaskIntoConstraints = NO;
    [power setImage:[UIImage systemImageNamed:@"power"] forState:UIControlStateNormal];
    power.tintColor = WQLRGB(0xF2F5FB);
    power.backgroundColor = WQLRGBA(0xFFFFFF, 0.06);
    power.layer.cornerRadius = 44;
    power.layer.borderWidth = 1;
    power.layer.borderColor = WQLRGBA(0xFFFFFF, 0.12).CGColor;
    power.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 0);
    [power addTarget:self action:@selector(onPower) forControlEvents:UIControlEventTouchUpInside];
    [ringHost addSubview:power];
    self.powerButton = power;
    power.imageView.contentMode = UIViewContentModeScaleAspectFit;
    power.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [power setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightRegular]
                                 forState:UIControlStateNormal];

    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = @"未连接";
    status.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    status.textColor = WQLRGB(0x9AA6BD);
    status.textAlignment = NSTextAlignmentCenter;
    [content addSubview:status];
    self.statusLabel = status;

    UILabel *subStatus = [UILabel new];
    subStatus.translatesAutoresizingMaskIntoConstraints = NO;
    subStatus.text = @"点击上方按钮开始连接";
    subStatus.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subStatus.textColor = WQLRGB(0x5B667E);
    subStatus.textAlignment = NSTextAlignmentCenter;
    [content addSubview:subStatus];
    self.subStatusLabel = subStatus;

    // ---- 统计卡 ----
    UIView *stats = [UIView new];
    stats.translatesAutoresizingMaskIntoConstraints = NO;
    stats.backgroundColor = WQLRGBA(0xFFFFFF, 0.035);
    stats.layer.cornerRadius = 16;
    stats.layer.borderWidth = 1;
    stats.layer.borderColor = WQLRGBA(0xFFFFFF, 0.07).CGColor;
    [content addSubview:stats];

    UILabel *durCap = [self captionLabel:@"连接时长"];
    UILabel *downCap = [self captionLabel:@"下载"];
    UILabel *upCap = [self captionLabel:@"上传"];
    [stats addSubview:durCap];
    [stats addSubview:downCap];
    [stats addSubview:upCap];

    self.durationLabel = [self valueLabel:@"00:00"];
    self.downLabel = [self valueLabel:@"0 KB"];
    self.upLabel = [self valueLabel:@"0 KB"];
    for (UILabel *l in @[self.durationLabel, self.downLabel, self.upLabel]) [stats addSubview:l];

    UIView *sep1 = [UIView new];
    sep1.translatesAutoresizingMaskIntoConstraints = NO;
    sep1.backgroundColor = WQLRGBA(0xFFFFFF, 0.06);
    [stats addSubview:sep1];
    UIView *sep2 = [UIView new];
    sep2.translatesAutoresizingMaskIntoConstraints = NO;
    sep2.backgroundColor = WQLRGBA(0xFFFFFF, 0.06);
    [stats addSubview:sep2];

    [NSLayoutConstraint activateConstraints:@[
        // 品牌栏
        [logo.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [logo.topAnchor constraintEqualToAnchor:content.topAnchor constant:6],
        [logo.widthAnchor constraintEqualToConstant:38],
        [logo.heightAnchor constraintEqualToConstant:38],

        [brand.leadingAnchor constraintEqualToAnchor:logo.trailingAnchor constant:10],
        [brand.topAnchor constraintEqualToAnchor:logo.topAnchor constant:1],

        [brandSub.leadingAnchor constraintEqualToAnchor:brand.leadingAnchor],
        [brandSub.topAnchor constraintEqualToAnchor:brand.bottomAnchor constant:1],

        [gear.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [gear.centerYAnchor constraintEqualToAnchor:logo.centerYAnchor],
        [gear.widthAnchor constraintEqualToConstant:32],
        [gear.heightAnchor constraintEqualToConstant:32],

        // 环
        [ringHost.topAnchor constraintEqualToAnchor:logo.bottomAnchor constant:22],
        [ringHost.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [ringHost.widthAnchor constraintEqualToConstant:252],
        [ringHost.heightAnchor constraintEqualToConstant:252],

        [power.centerXAnchor constraintEqualToAnchor:ringHost.centerXAnchor],
        [power.centerYAnchor constraintEqualToAnchor:ringHost.centerYAnchor],
        [power.widthAnchor constraintEqualToConstant:88],
        [power.heightAnchor constraintEqualToConstant:88],

        [status.topAnchor constraintEqualToAnchor:ringHost.bottomAnchor constant:6],
        [status.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [status.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],

        [subStatus.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:5],
        [subStatus.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [subStatus.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],

        // 统计卡
        [stats.topAnchor constraintEqualToAnchor:subStatus.bottomAnchor constant:18],
        [stats.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [stats.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [stats.heightAnchor constraintEqualToConstant:78],
    ]];

    // 三列等分
    [NSLayoutConstraint activateConstraints:@[
        [durCap.leadingAnchor constraintEqualToAnchor:stats.leadingAnchor],
        [durCap.widthAnchor constraintEqualToAnchor:stats.widthAnchor multiplier:1.0 / 3.0],
        [downCap.leadingAnchor constraintEqualToAnchor:durCap.trailingAnchor],
        [downCap.widthAnchor constraintEqualToAnchor:stats.widthAnchor multiplier:1.0 / 3.0],
        [upCap.leadingAnchor constraintEqualToAnchor:downCap.trailingAnchor],
        [upCap.widthAnchor constraintEqualToAnchor:stats.widthAnchor multiplier:1.0 / 3.0],

        [durCap.topAnchor constraintEqualToAnchor:stats.topAnchor constant:16],
        [downCap.topAnchor constraintEqualToAnchor:durCap.topAnchor],
        [upCap.topAnchor constraintEqualToAnchor:durCap.topAnchor],

        [self.durationLabel.topAnchor constraintEqualToAnchor:durCap.bottomAnchor constant:6],
        [self.durationLabel.centerXAnchor constraintEqualToAnchor:durCap.centerXAnchor],
        [self.downLabel.topAnchor constraintEqualToAnchor:self.durationLabel.topAnchor],
        [self.downLabel.centerXAnchor constraintEqualToAnchor:downCap.centerXAnchor],
        [self.upLabel.topAnchor constraintEqualToAnchor:self.durationLabel.topAnchor],
        [self.upLabel.centerXAnchor constraintEqualToAnchor:upCap.centerXAnchor],

        [sep1.topAnchor constraintEqualToAnchor:stats.topAnchor constant:14],
        [sep1.bottomAnchor constraintEqualToAnchor:stats.bottomAnchor constant:-14],
        [sep1.centerXAnchor constraintEqualToAnchor:downCap.leadingAnchor],
        [sep1.widthAnchor constraintEqualToConstant:1],
        [sep2.topAnchor constraintEqualToAnchor:sep1.topAnchor],
        [sep2.bottomAnchor constraintEqualToAnchor:sep1.bottomAnchor],
        [sep2.centerXAnchor constraintEqualToAnchor:upCap.leadingAnchor],
        [sep2.widthAnchor constraintEqualToConstant:1],
    ]];

    // ---- 线路列表 ----
    UILabel *listTitle = [UILabel new];
    listTitle.translatesAutoresizingMaskIntoConstraints = NO;
    listTitle.attributedText = [[NSAttributedString alloc]
        initWithString:@"线路选择"
            attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: WQLRGB(0x6B7793),
                NSKernAttributeName: @1.2
            }];
    [content addSubview:listTitle];

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [content addSubview:stack];

    self.rows = [NSMutableArray array];
    for (WQLVpnServer *s in self.servers) {
        WQLVpnServerRow *row = [[WQLVpnServerRow alloc] initWithServer:s];
        [row addTarget:self action:@selector(onRowTap:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:row];
        [row.heightAnchor constraintEqualToConstant:62].active = YES;
        [self.rows addObject:row];
    }

    UILabel *foot = [UILabel new];
    foot.translatesAutoresizingMaskIntoConstraints = NO;
    foot.text = @"连接后设备流量将经加密通道转发";
    foot.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    foot.textColor = WQLRGBA(0xFFFFFF, 0.22);
    foot.textAlignment = NSTextAlignmentCenter;
    foot.numberOfLines = 0;
    [content addSubview:foot];

    [NSLayoutConstraint activateConstraints:@[
        [listTitle.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:22],
        [listTitle.topAnchor constraintEqualToAnchor:stats.bottomAnchor constant:22],

        [stack.topAnchor constraintEqualToAnchor:listTitle.bottomAnchor constant:10],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],

        [foot.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:16],
        [foot.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [foot.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [foot.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],
    ]];

    [self updateRowSelection];
}

- (UILabel *)captionLabel:(NSString *)text {
    UILabel *l = [UILabel new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    l.textColor = WQLRGB(0x5B667E);
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}

- (UILabel *)valueLabel:(NSString *)text {
    UILabel *l = [UILabel new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    l.textColor = WQLRGB(0xE8EEF9);
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}

#pragma mark - 连接环绘制

- (void)layoutRing {
    if (!self.ringHost || self.ringHost.bounds.size.width <= 0) return;

    if (!self.trackLayer) {
        CGRect b = self.ringHost.bounds;
        CGFloat lineW = 7.0;
        CGRect oval = CGRectInset(b, lineW / 2 + 6, lineW / 2 + 6);
        UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:oval];

        CAShapeLayer *track = [CAShapeLayer layer];
        track.path = path.CGPath;
        track.fillColor = [UIColor clearColor].CGColor;
        track.strokeColor = WQLRGBA(0xFFFFFF, 0.08).CGColor;
        track.lineWidth = lineW;
        [self.ringHost.layer addSublayer:track];
        self.trackLayer = track;

        CAShapeLayer *prog = [CAShapeLayer layer];
        prog.path = path.CGPath;
        prog.fillColor = [UIColor clearColor].CGColor;
        prog.strokeColor = WQLRGB(0x38E8FF).CGColor;
        prog.lineWidth = lineW;
        prog.lineCap = kCALineCapRound;
        prog.strokeStart = 0;
        prog.strokeEnd = 0;
        CGAffineTransform rot = CGAffineTransformMakeRotation(-M_PI_2);
        prog.affineTransform = rot;
        prog.frame = b;
        [self.ringHost.layer addSublayer:prog];
        self.progressLayer = prog;

        // 外圈细光环
        CAShapeLayer *halo = [CAShapeLayer layer];
        halo.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(b, 2, 2)].CGPath;
        halo.fillColor = [UIColor clearColor].CGColor;
        halo.strokeColor = WQLRGBA(0x3B7BFF, 0.18).CGColor;
        halo.lineWidth = 1;
        [self.ringHost.layer insertSublayer:halo below:track];
    }
}

#pragma mark - 状态

- (void)onPower {
    switch (self.state) {
        case WQLVpnStateIdle:
            [self connect];
            break;
        case WQLVpnStateConnecting:
            [self disconnectWithText:@"已取消"];
            break;
        case WQLVpnStateConnected:
            [self disconnectWithText:@"已断开连接"];
            break;
    }
}

- (void)connect {
    if (!self.current) return;
    self.state = WQLVpnStateConnecting;

    self.statusLabel.text = @"正在连接…";
    self.statusLabel.textColor = WQLRGB(0x38E8FF);
    self.subStatusLabel.text = [NSString stringWithFormat:@"%@ %@ · 建立加密隧道",
                                self.current.name, self.current.code];
    self.powerButton.tintColor = WQLRGB(0x38E8FF);
    self.powerButton.layer.borderColor = WQLRGBA(0x38E8FF, 0.45).CGColor;
    self.progressLayer.strokeColor = WQLRGB(0x38E8FF).CGColor;

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        if (self.state != WQLVpnStateConnecting) return;
        [self didConnect];
    }];
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    anim.fromValue = @0.0;
    anim.toValue = @1.0;
    anim.duration = 1.15;
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.progressLayer addAnimation:anim forKey:@"connect"];
    self.progressLayer.strokeEnd = 1.0;
    [CATransaction commit];
}

- (void)didConnect {
    self.state = WQLVpnStateConnected;
    self.startedAt = [NSDate date].timeIntervalSince1970;
    self.seconds = 0;
    self.downBytes = 0;
    self.upBytes = 0;

    self.statusLabel.text = @"已连接";
    self.statusLabel.textColor = WQLRGB(0x2EE6A8);
    self.subStatusLabel.text = [NSString stringWithFormat:@"%@ %@ · %@",
                                self.current.name, self.current.code, self.current.ip];
    self.powerButton.tintColor = WQLRGB(0x2EE6A8);
    self.powerButton.layer.borderColor = WQLRGBA(0x2EE6A8, 0.5).CGColor;
    self.powerButton.backgroundColor = WQLRGBA(0x2EE6A8, 0.10);
    self.progressLayer.strokeColor = WQLRGB(0x2EE6A8).CGColor;

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.45;
    pulse.duration = 1.6;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.progressLayer addAnimation:pulse forKey:@"pulse"];

    [self startTicker];
    WQLLogLine(@"VPN 演示: 已连接到 %@ %@", self.current.name, self.current.code);
}

- (void)disconnectWithText:(NSString *)text {
    self.state = WQLVpnStateIdle;
    [self stopTicker];
    [self.progressLayer removeAllAnimations];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.progressLayer.strokeEnd = 0;
    [CATransaction commit];

    self.statusLabel.text = @"未连接";
    self.statusLabel.textColor = WQLRGB(0x9AA6BD);
    self.subStatusLabel.text = text.length ? text : @"点击上方按钮开始连接";
    self.powerButton.tintColor = WQLRGB(0xF2F5FB);
    self.powerButton.layer.borderColor = WQLRGBA(0xFFFFFF, 0.12).CGColor;
    self.powerButton.backgroundColor = WQLRGBA(0xFFFFFF, 0.06);
    self.durationLabel.text = @"00:00";
    self.downLabel.text = @"0 KB";
    self.upLabel.text = @"0 KB";
}

#pragma mark - 线路

- (void)onRowTap:(WQLVpnServerRow *)row {
    if (self.current == row.server) {
        if (self.state == WQLVpnStateIdle) [self connect];
        return;
    }
    BOOL wasActive = (self.state != WQLVpnStateIdle);
    self.current = row.server;
    [self updateRowSelection];

    if (wasActive) {
        [self disconnectWithText:@"切换线路中…"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self connect];
        });
    } else {
        self.subStatusLabel.text = [NSString stringWithFormat:@"已选择 %@ %@",
                                    row.server.name, row.server.code];
    }
}

- (void)updateRowSelection {
    for (WQLVpnServerRow *r in self.rows) {
        [r setSelectedStyle:(r.server == self.current)];
    }
}

#pragma mark - 计时

- (void)startTicker {
    [self.ticker invalidate];
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   target:self
                                                 selector:@selector(onTick)
                                                 userInfo:nil
                                                  repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.ticker forMode:NSRunLoopCommonModes];
}

- (void)stopTicker {
    [self.ticker invalidate];
    self.ticker = nil;
}

- (void)onTick {
    if (self.state != WQLVpnStateConnected) return;
    self.seconds += 1;
    self.downBytes += 42 * 1024 + (arc4random_uniform(90) * 1024);
    self.upBytes += 9 * 1024 + (arc4random_uniform(26) * 1024);

    NSInteger m = self.seconds / 60;
    NSInteger s = self.seconds % 60;
    self.durationLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
    self.downLabel.text = [self human:self.downBytes];
    self.upLabel.text = [self human:self.upBytes];
}

- (NSString *)human:(double)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%.0f B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024];
    if (bytes < 1024.0 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / (1024 * 1024)];
    return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0 * 1024 * 1024)];
}

#pragma mark - 其它

- (void)refreshUI {
    self.statusLabel.text = @"未连接";
    self.subStatusLabel.text = @"点击上方按钮开始连接";
}

- (void)onSettings {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"POLARIS VPN"
                                                                  message:@"版本 1.0.0  ·  传输协议 Polaris-2"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"协议与加密" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self showInfo:@"协议与加密"
               message:@"隧道：AES-256-GCM\n握手：X25519\nDNS：加密解析，不记录查询日志"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"关于" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self showInfo:@"北极星 VPN" message:@"版本 1.0.0 (Build 100)\n© 2026 Polaris Network"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width - 40, 60, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showInfo:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
