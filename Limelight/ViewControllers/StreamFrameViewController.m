//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#include <Limelight.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

static NSArray<NSArray<NSString *> *> *statsItemDefs(void);

// Windows virtual-key codes
#define VK_WIN 0x5B
#define VK_CTRL 0xA2
#define VK_ALT 0xA4
#define VK_SHIFT 0xA0

// Self-drawn option group (replaces UISegmentedControl in the side panel).
// Mirrors the segmented API we use: selectedSegmentIndex + UIControlEventValueChanged.
@interface MLOptionGroup : UIControl
- (instancetype)initWithItems:(NSArray<NSString *> *)items;
@property (nonatomic) NSInteger selectedSegmentIndex;
@end

@implementation MLOptionGroup {
    NSArray<UIButton *> *_buttons;
}

- (instancetype)initWithItems:(NSArray<NSString *> *)items {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        NSMutableArray *bs = [NSMutableArray array];
        for (NSUInteger i = 0; i < items.count; i++) {
            UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
            cfg.title = items[i];
            cfg.baseForegroundColor = UIColor.whiteColor;
            cfg.background.cornerRadius = 10;
            // Narrow side panel: tight insets + single line, otherwise UIKit wraps "1080p" into a vertical column
            cfg.contentInsets = NSDirectionalEdgeInsetsMake(4, 3, 4, 3);
            cfg.titleLineBreakMode = NSLineBreakByClipping;
            cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attrs) {
                NSMutableDictionary *m = [attrs mutableCopy];
                m[NSFontAttributeName] = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
                return m;
            };
            __weak typeof(self) ws = self;
            UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
                [ws tapped:i];
            }]];
            b.titleLabel.numberOfLines = 1;
            b.titleLabel.adjustsFontSizeToFitWidth = YES;
            b.titleLabel.minimumScaleFactor = 0.7;
            [bs addObject:b];
        }
        _buttons = bs;
        // Wrap into rows: up to 4 per row when it fits in one, otherwise 3 per row
        NSUInteger perRow = bs.count <= 4 ? MAX(bs.count, 1) : 3;
        UIStackView *grid = [[UIStackView alloc] init];
        grid.axis = UILayoutConstraintAxisVertical;
        grid.spacing = 8;
        grid.translatesAutoresizingMaskIntoConstraints = NO;
        for (NSUInteger start = 0; start < bs.count; start += perRow) {
            UIStackView *row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.distribution = UIStackViewDistributionFillEqually;
            row.spacing = 8;
            for (NSUInteger k = 0; k < perRow; k++) {
                // Pad the last row with empty cells so every button keeps the same width
                [row addArrangedSubview:start + k < bs.count ? bs[start + k] : [[UIView alloc] init]];
            }
            [row.heightAnchor constraintEqualToConstant:42].active = YES;
            [grid addArrangedSubview:row];
        }
        [self addSubview:grid];
        [NSLayoutConstraint activateConstraints:@[
            [grid.topAnchor constraintEqualToAnchor:self.topAnchor],
            [grid.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [grid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [grid.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
        _selectedSegmentIndex = -1;
        [self restyle];
    }
    return self;
}

- (void)tapped:(NSUInteger)i {
    [[UISelectionFeedbackGenerator new] selectionChanged];
    self.selectedSegmentIndex = i;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)setSelectedSegmentIndex:(NSInteger)idx {
    _selectedSegmentIndex = idx;
    [self restyle];
}

- (void)restyle {
    for (NSUInteger i = 0; i < _buttons.count; i++) {
        UIButton *b = _buttons[i];
        UIButtonConfiguration *c = b.configuration;
        BOOL on = (NSInteger)i == _selectedSegmentIndex;
        c.background.backgroundColor = on ? [UIColor.systemGreenColor colorWithAlphaComponent:0.55] : [UIColor colorWithWhite:1 alpha:0.1];
        c.background.strokeColor = on ? [UIColor.systemGreenColor colorWithAlphaComponent:0.9] : UIColor.clearColor;
        c.background.strokeWidth = on ? 1 : 0;
        b.configuration = c;
    }
}
@end

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    CGSize _keyboardSize;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
    // 月光 right side panel
    UIScreenEdgePanGestureRecognizer *_sideEdgeRecognizer;
    UIButton *_sideHandle;
    UIView *_sideDim;
    UIVisualEffectView *_sidePanel;
    MLOptionGroup *_oscSegment;
    MLOptionGroup *_statsSegment;
    MLOptionGroup *_touchSegment;
    UILabel *_compactStatsLabel;
    NSInteger _statsMode; // 0 off, 1 compact, 2 full
    NSMutableSet<NSString *> *_statsItemsOn;
    NSMutableArray<UIButton *> *_statsItemButtons;
    BOOL _sidePanelOpen;
    NSArray<NSArray *> *_comboKeys;
    UIStackView *_customComboStack;
    NSMutableArray<NSDictionary *> *_customCombos;
    UIView *_sidePageHost;
    UIView *_sideRootPage;
    UIView *_sideCurrentPage;
    NSMutableDictionary<NSString *, UIView *> *_sidePages;
    NSMutableDictionary<NSString *, UILabel *> *_sideRowValues;
    UILabel *_sideClockLabel;
    UIButton *_statsTile;
    UIButton *_oscTile;
    UIButton *_touchTile;
    NSInteger _lastStatsMode;
    OnScreenControlsLevel _lastOscLevel;
    MLOptionGroup *_resGroup;
    MLOptionGroup *_fpsGroup;
    MLOptionGroup *_bitrateGroup;
    BOOL _reconnecting;
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
#endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.frame];
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Tip: Swipe from the left edge to disconnect from your PC"];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    // Only enable scroll and zoom in absolute touch mode
    if (_settings.absoluteTouchMode) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.frame];
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view addSubview:_scrollView];
    }
    else {
        // Add StreamView directly in relative mode
        [self.view addSubview:_streamView];
    }
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];
#if !TARGET_OS_TV
    [self setupSidePanel];
#endif
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
#if !TARGET_OS_TV
    if (_statsMode == 1) {
        NSDictionary *d = [self->_streamMan getStatsItems];
        if (d == nil) {
            [self updateCompactStats:nil];
            return;
        }
        NSMutableArray *lines = [NSMutableArray array];
        for (NSArray *def in statsItemDefs()) {
            if ([_statsItemsOn containsObject:def[0]] && d[def[0]] != nil) {
                [lines addObject:[NSString stringWithFormat:@"%@  %@", def[1], d[def[0]]]];
            }
        }
        [self updateCompactStats:lines.count ? [lines componentsJoinedByString:@"\n"] : @"（未选任何项）"];
        return;
    }
#endif
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
#if !TARGET_OS_TV
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    [self returnToMainFrame];
}

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    
    [self returnToMainFrame];
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        
        [self->_streamView showOnScreenControls];
        
        [self->_controllerSupport connectionEstablished];
        
        if (self->_reconnecting) {
            // In-stream quality change: keep the user's current stats mode/timer
            self->_reconnecting = NO;
            return;
        }
        
        if (self->_settings.statsOverlay) {
#if !TARGET_OS_TV
            self->_statsMode = 2;
#endif
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    if (_reconnecting) {
        return;
    }
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
#pragma mark - 月光 side panel

static const CGFloat kSideHandleWidth = 18;
static const CGFloat kSideHandleHeight = 64;

- (void)setupSidePanel {
    _sideHandle = [UIButton buttonWithType:UIButtonTypeCustom];
    _sideHandle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _sideHandle.layer.cornerRadius = 8;
    _sideHandle.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    _sideHandle.tintColor = [UIColor colorWithWhite:1 alpha:0.75];
    [_sideHandle setImage:[UIImage systemImageNamed:@"chevron.compact.left"] forState:UIControlStateNormal];
    [_sideHandle addTarget:self action:@selector(openSidePanel) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *handlePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(sidePanStarted:)];
    [_sideHandle addGestureRecognizer:handlePan];

    _sideEdgeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(sidePanStarted:)];
    _sideEdgeRecognizer.edges = UIRectEdgeRight;
    _sideEdgeRecognizer.delaysTouchesBegan = NO;
    _sideEdgeRecognizer.delaysTouchesEnded = NO;
    [self.view addGestureRecognizer:_sideEdgeRecognizer];

    _sideDim = [[UIView alloc] init];
    _sideDim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
    _sideDim.alpha = 0;
    _sideDim.hidden = YES;
    [_sideDim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeSidePanel)]];

    _sidePanel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    _sidePanel.hidden = YES;
    UISwipeGestureRecognizer *swipeClose = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(closeSidePanel)];
    swipeClose.direction = UISwipeGestureRecognizerDirectionRight;
    [_sidePanel addGestureRecognizer:swipeClose];

    __weak typeof(self) ws = self;
    UIView *content = _sidePanel.contentView;
    UILayoutGuide *g = content.safeAreaLayoutGuide;

    // Rail on the outer (thumb) edge: one-tap desktop actions, like 阿西西's right column
    UIView *railBg = [[UIView alloc] init];
    railBg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    railBg.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:railBg];
    UIStackView *rail = [[UIStackView alloc] init];
    rail.axis = UILayoutConstraintAxisVertical;
    rail.distribution = UIStackViewDistributionFillEqually;
    rail.spacing = 4;
    rail.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *railDefs = @[@[@"键盘", @"keyboard"], @[@"桌面", @"menubar.dock.rectangle"],
                          @[@"全部窗口", @"rectangle.3.group"], @[@"切换窗口", @"arrow.left.arrow.right.square"],
                          @[@"收起", @"chevron.right.2"]];
    NSArray *railActions = @[
        ^{ [ws sideKeyboardTapped]; },
        ^{ [ws sendCombo:@[@VK_WIN, @0x44]]; },
        ^{ [ws sendCombo:@[@VK_WIN, @0x09]]; },
        ^{ [ws sendCombo:@[@VK_ALT, @0x09]]; },
        ^{ [ws closeSidePanel]; },
    ];
    for (NSUInteger i = 0; i < railDefs.count; i++) {
        UIButton *b = [self sideTile:railDefs[i][0] symbol:railDefs[i][1] height:0 handler:railActions[i]];
        UIButtonConfiguration *c = b.configuration;
        c.background.backgroundColor = UIColor.clearColor;
        b.configuration = c;
        [rail addArrangedSubview:b];
    }
    [content addSubview:rail];

    _sidePageHost = [[UIView alloc] init];
    _sidePageHost.clipsToBounds = YES;
    _sidePageHost.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_sidePageHost];
    [NSLayoutConstraint activateConstraints:@[
        [rail.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [rail.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [rail.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
        [rail.widthAnchor constraintEqualToConstant:64],
        [railBg.leadingAnchor constraintEqualToAnchor:rail.leadingAnchor],
        [railBg.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [railBg.topAnchor constraintEqualToAnchor:content.topAnchor],
        [railBg.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [_sidePageHost.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_sidePageHost.trailingAnchor constraintEqualToAnchor:rail.leadingAnchor],
        [_sidePageHost.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_sidePageHost.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    ]];

    _sideRowValues = [NSMutableDictionary dictionary];
    _sidePages = [NSMutableDictionary dictionary];
    _sideRootPage = [self buildSideRootPage];
    [self buildSideSubPages];
    [self installSidePage:_sideRootPage];
    _sideCurrentPage = _sideRootPage;

    [self.view addSubview:_sideHandle];
    [self.view addSubview:_sideDim];
    [self.view addSubview:_sidePanel];
}

- (UIButton *)sideTile:(NSString *)title symbol:(NSString *)symbol height:(CGFloat)h handler:(void (^)(void))handler {
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = title;
    cfg.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium]];
    cfg.imagePlacement = NSDirectionalRectEdgeTop;
    cfg.imagePadding = 5;
    cfg.baseForegroundColor = UIColor.whiteColor;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 2, 6, 2);
    cfg.background.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    cfg.background.cornerRadius = 10;
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attrs) {
        NSMutableDictionary *m = [attrs mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        return m;
    };
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { handler(); }]];
    if (h > 0) {
        [b.heightAnchor constraintEqualToConstant:h].active = YES;
    }
    return b;
}

- (UIStackView *)sideTileRow:(NSArray<UIView *> *)tiles {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:tiles];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    return row;
}

- (UILabel *)sideSectionLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    return l;
}

- (UIButton *)sideNavRow:(NSString *)title symbol:(NSString *)symbol page:(NSString *)key {
    __weak typeof(self) ws = self;
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = title;
    cfg.image = [UIImage systemImageNamed:symbol];
    cfg.imagePadding = 10;
    cfg.baseForegroundColor = UIColor.whiteColor;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(0, 12, 0, 12);
    cfg.background.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    cfg.background.cornerRadius = 10;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [ws pushSidePage:key]; }]];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [b.heightAnchor constraintEqualToConstant:46].active = YES;
    UILabel *v = [[UILabel alloc] init];
    v.font = [UIFont systemFontOfSize:13];
    v.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    UIImageView *chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chev.tintColor = [UIColor colorWithWhite:1 alpha:0.35];
    UIStackView *trail = [[UIStackView alloc] initWithArrangedSubviews:@[v, chev]];
    trail.spacing = 6;
    trail.alignment = UIStackViewAlignmentCenter;
    trail.userInteractionEnabled = NO;
    trail.translatesAutoresizingMaskIntoConstraints = NO;
    [b addSubview:trail];
    [NSLayoutConstraint activateConstraints:@[
        [trail.trailingAnchor constraintEqualToAnchor:b.trailingAnchor constant:-12],
        [trail.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
    ]];
    _sideRowValues[key] = v;
    return b;
}

- (UIView *)sideScrollPage:(UIStackView *)stack {
    UIView *page = [[UIView alloc] init];
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:page.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:page.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:page.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:page.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-14],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-12],
    ]];
    return page;
}

- (UIView *)buildSideRootPage {
    __weak typeof(self) ws = self;
    UILabel *title = [[UILabel alloc] init];
    title.text = @"月光";
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textColor = UIColor.whiteColor;
    _sideClockLabel = [[UILabel alloc] init];
    _sideClockLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _sideClockLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    _sideClockLabel.textAlignment = NSTextAlignmentRight;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, _sideClockLabel]];
    header.alignment = UIStackViewAlignmentCenter;

    UIButton *dc = [self sideTile:@"断开" symbol:@"xmark.circle" height:60 handler:^{ [ws sideDisconnectTapped]; }];
    UIButtonConfiguration *dcfg = dc.configuration;
    dcfg.baseForegroundColor = UIColor.systemRedColor;
    dc.configuration = dcfg;
    _statsTile = [self sideTile:@"性能" symbol:@"speedometer" height:60 handler:^{ [ws statsTileTapped]; }];
    [_statsTile addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(statsTileLongPressed:)]];
    _oscTile = [self sideTile:@"手柄" symbol:@"gamecontroller" height:60 handler:^{ [ws oscTileTapped]; }];
    [_oscTile addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(oscTileLongPressed:)]];
    _touchTile = [self sideTile:@"触控板" symbol:@"hand.point.up.left" height:60 handler:^{ [ws touchTileTapped]; }];
    UIButton *explorer = [self sideTile:@"资源管理" symbol:@"folder" height:60 handler:^{ [ws sendCombo:@[@VK_WIN, @0x45]]; }];
    UIButton *taskmgr = [self sideTile:@"任务管理" symbol:@"list.bullet.rectangle" height:60 handler:^{ [ws sendCombo:@[@VK_CTRL, @VK_SHIFT, @0x1B]]; }];
    UIButton *shot = [self sideTile:@"截图" symbol:@"camera.viewfinder" height:60 handler:^{ [ws sendCombo:@[@VK_WIN, @VK_SHIFT, @0x53]]; }];
    UIButton *esc = [self sideTile:@"Esc" symbol:@"escape" height:60 handler:^{ [ws sendCombo:@[@0x1B]]; }];

    UIStackView *rows = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self sideNavRow:@"画质" symbol:@"sparkles.tv" page:@"quality"],
        [self sideNavRow:@"快捷键" symbol:@"command" page:@"combo"],
        [self sideNavRow:@"性能信息" symbol:@"speedometer" page:@"stats"],
        [self sideNavRow:@"虚拟手柄" symbol:@"gamecontroller" page:@"osc"],
        [self sideNavRow:@"触控模式" symbol:@"cursorarrow.motionlines" page:@"touch"],
    ]];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 6;

    UILabel *section = [self sideSectionLabel:@"功能设置"];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        header,
        [self sideTileRow:@[dc, _statsTile, _oscTile, _touchTile]],
        [self sideTileRow:@[explorer, taskmgr, shot, esc]],
        section, rows]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [stack setCustomSpacing:14 afterView:header];
    [stack setCustomSpacing:18 afterView:stack.arrangedSubviews[2]];
    return [self sideScrollPage:stack];
}

- (UIStackView *)sideSubStack:(NSString *)title {
    __weak typeof(self) ws = self;
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = title;
    cfg.image = [UIImage systemImageNamed:@"chevron.left"];
    cfg.imagePadding = 6;
    cfg.baseForegroundColor = UIColor.whiteColor;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(4, 0, 4, 0);
    cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attrs) {
        NSMutableDictionary *m = [attrs mutableCopy];
        m[NSFontAttributeName] = [UIFont boldSystemFontOfSize:18];
        return m;
    };
    UIButton *back = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [ws popSidePage]; }]];
    back.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[back]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [stack setCustomSpacing:14 afterView:back];
    return stack;
}

- (UILabel *)sideHint:(NSString *)text {
    UILabel *l = [self sideSectionLabel:text];
    l.font = [UIFont systemFontOfSize:12];
    l.numberOfLines = 0;
    return l;
}

- (void)buildSideSubPages {
    UIStackView *combo = [self sideSubStack:@"快捷键"];
    [self addComboSectionsToStack:combo];
    _sidePages[@"combo"] = [self sideScrollPage:combo];

    UIStackView *stats = [self sideSubStack:@"性能信息"];
    _statsSegment = [[MLOptionGroup alloc] initWithItems:@[@"关", @"详细", @"原版"]];
    [_statsSegment addTarget:self action:@selector(statsSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [stats addArrangedSubview:_statsSegment];
    [stats setCustomSpacing:16 afterView:_statsSegment];
    [stats addArrangedSubview:[self sideSectionLabel:@"显示项（详细模式，点选开关）"]];
    [stats addArrangedSubview:[self statsItemGrid]];
    [stats addArrangedSubview:[self sideHint:@"主菜单的「性能信息」按钮可一键开关；长按直接进这一页。"]];
    _sidePages[@"stats"] = [self sideScrollPage:stats];

    UIStackView *osc = [self sideSubStack:@"虚拟手柄"];
    _oscSegment = [[MLOptionGroup alloc] initWithItems:@[@"关", @"简易", @"完整"]];
    [_oscSegment addTarget:self action:@selector(oscSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [osc addArrangedSubview:_oscSegment];
    [osc addArrangedSubview:[self sideHint:@"主菜单按钮在「关」和上次的档位之间切换。"]];
    _sidePages[@"osc"] = [self sideScrollPage:osc];

    UIStackView *touch = [self sideSubStack:@"触控模式"];
    _touchSegment = [[MLOptionGroup alloc] initWithItems:@[@"触控板", @"直接点击"]];
    [_touchSegment addTarget:self action:@selector(touchSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [touch addArrangedSubview:_touchSegment];
    [touch addArrangedSubview:[self sideHint:@"触控板：手指滑动移动光标，轻点为左键。\n直接点击：点哪里就点哪里。"]];
    _sidePages[@"touch"] = [self sideScrollPage:touch];

    __weak typeof(self) ws = self;
    UIStackView *q = [self sideSubStack:@"画质"];
    [q addArrangedSubview:[self sideSectionLabel:@"分辨率"]];
    _resGroup = [[MLOptionGroup alloc] initWithItems:@[@"720p", @"1080p", @"1440p", @"4K", @"本机"]];
    [q addArrangedSubview:_resGroup];
    [q setCustomSpacing:14 afterView:_resGroup];
    [q addArrangedSubview:[self sideSectionLabel:@"帧率"]];
    _fpsGroup = [[MLOptionGroup alloc] initWithItems:@[@"30", @"60", @"90", @"120"]];
    [q addArrangedSubview:_fpsGroup];
    [q setCustomSpacing:14 afterView:_fpsGroup];
    [q addArrangedSubview:[self sideSectionLabel:@"码率 (Mbps)"]];
    _bitrateGroup = [[MLOptionGroup alloc] initWithItems:@[@"5", @"10", @"20", @"30", @"50", @"80"]];
    [q addArrangedSubview:_bitrateGroup];
    [q setCustomSpacing:18 afterView:_bitrateGroup];
    UIButton *apply = [self sideTile:@"应用并重连" symbol:@"arrow.triangle.2.circlepath" height:56 handler:^{ [ws applyQualityTapped]; }];
    UIButtonConfiguration *ac = apply.configuration;
    ac.background.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.55];
    apply.configuration = ac;
    [q addArrangedSubview:apply];
    [q addArrangedSubview:[self sideHint:@"点「应用」后画面断开约 2 秒，用新参数重连，游戏不受影响。只改本次串流，不改默认设置。"]];
    _sidePages[@"quality"] = [self sideScrollPage:q];
}

static NSArray<NSArray<NSNumber *> *> *qualityResDefs(void) {
    return @[@[@1280, @720], @[@1920, @1080], @[@2560, @1440], @[@3840, @2160], @[@0, @0]];
}
static NSArray<NSNumber *> *qualityFpsDefs(void) { return @[@30, @60, @90, @120]; }
static NSArray<NSNumber *> *qualityBitrateDefs(void) { return @[@5, @10, @20, @30, @50, @80]; }

- (CGSize)nativeStreamSize {
    CGSize n = UIScreen.mainScreen.nativeBounds.size;
    int w = ((int)MAX(n.width, n.height)) & ~1;
    int h = ((int)MIN(n.width, n.height)) & ~1;
    return CGSizeMake(w, h);
}

- (void)syncQualityGroups {
    StreamConfiguration *c = self.streamConfig;
    NSInteger ri = -1;
    NSArray *res = qualityResDefs();
    CGSize native = [self nativeStreamSize];
    for (NSInteger i = 0; i < (NSInteger)res.count; i++) {
        int w = [res[i][0] intValue], h = [res[i][1] intValue];
        if (w == 0) { w = native.width; h = native.height; }
        if (w == c.width && h == c.height) { ri = i; break; }
    }
    _resGroup.selectedSegmentIndex = ri;
    _fpsGroup.selectedSegmentIndex = [qualityFpsDefs() indexOfObject:@(c.frameRate)] == NSNotFound ? -1 : [qualityFpsDefs() indexOfObject:@(c.frameRate)];
    NSUInteger bi = [qualityBitrateDefs() indexOfObject:@(c.bitRate / 1000)];
    _bitrateGroup.selectedSegmentIndex = bi == NSNotFound ? -1 : bi;
}

- (NSString *)qualitySummary {
    StreamConfiguration *c = self.streamConfig;
    return [NSString stringWithFormat:@"%dp · %d · %dM", c.height, c.frameRate, c.bitRate / 1000];
}

- (void)applyQualityTapped {
    StreamConfiguration *c = self.streamConfig;
    int w = c.width, h = c.height, fps = c.frameRate, kbps = c.bitRate;
    if (_resGroup.selectedSegmentIndex >= 0) {
        NSArray *r = qualityResDefs()[_resGroup.selectedSegmentIndex];
        w = [r[0] intValue]; h = [r[1] intValue];
        if (w == 0) { CGSize n = [self nativeStreamSize]; w = n.width; h = n.height; }
    }
    if (_fpsGroup.selectedSegmentIndex >= 0) {
        fps = [qualityFpsDefs()[_fpsGroup.selectedSegmentIndex] intValue];
    }
    if (_bitrateGroup.selectedSegmentIndex >= 0) {
        kbps = [qualityBitrateDefs()[_bitrateGroup.selectedSegmentIndex] intValue] * 1000;
    }
    if (w == c.width && h == c.height && fps == c.frameRate && kbps == c.bitRate) {
        [self closeSidePanel];
        return;
    }
    c.width = w;
    c.height = h;
    c.frameRate = fps;
    c.bitRate = kbps;
    [self closeSidePanel];
    [self restartStreamWithCurrentConfig];
}

- (void)restartStreamWithCurrentConfig {
    _reconnecting = YES;
    [_streamMan stopStream];
    // Old renderer's layer would sit on top of the new one; drop it now
    for (CALayer *l in [_streamView.layer.sublayers copy]) {
        if ([l isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
            [l removeFromSuperlayer];
        }
    }
    [_streamView setStreamAspectRatio:(float)self.streamConfig.width / (float)self.streamConfig.height];
    _stageLabel.text = @"正在用新画质重连…";
    [_stageLabel sizeToFit];
    _stageLabel.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2 + 50);
    _stageLabel.hidden = NO;
    [self.view bringSubviewToFront:_stageLabel];
    [self.view bringSubviewToFront:_spinner];
    [_spinner startAnimating];
    // Give LiStopConnection (async, under initLock) a head start so the host tears the old session down first
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                                      renderView:self->_streamView
                                             connectionCallbacks:self];
        NSOperationQueue *q = [[NSOperationQueue alloc] init];
        [q addOperation:self->_streamMan];
    });
}

- (void)installSidePage:(UIView *)p {
    p.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidePageHost addSubview:p];
    [NSLayoutConstraint activateConstraints:@[
        [p.topAnchor constraintEqualToAnchor:_sidePageHost.topAnchor],
        [p.bottomAnchor constraintEqualToAnchor:_sidePageHost.bottomAnchor],
        [p.leadingAnchor constraintEqualToAnchor:_sidePageHost.leadingAnchor],
        [p.trailingAnchor constraintEqualToAnchor:_sidePageHost.trailingAnchor],
    ]];
}

- (void)pushSidePage:(NSString *)key {
    UIView *p = _sidePages[key];
    if (p == nil || p == _sideCurrentPage) {
        return;
    }
    [self refreshSideTiles];
    UIView *old = _sideCurrentPage;
    _sideCurrentPage = p;
    [self installSidePage:p];
    CGFloat w = _sidePageHost.bounds.size.width;
    p.transform = CGAffineTransformMakeTranslation(w, 0);
    [UIView animateWithDuration:0.22 animations:^{
        p.transform = CGAffineTransformIdentity;
        old.transform = CGAffineTransformMakeTranslation(-w * 0.3, 0);
        old.alpha = 0;
    } completion:^(BOOL f) {
        if (old != self->_sideCurrentPage) {
            [old removeFromSuperview];
        }
        old.transform = CGAffineTransformIdentity;
        old.alpha = 1;
    }];
}

- (void)popSidePage {
    if (_sideCurrentPage == _sideRootPage) {
        return;
    }
    [self refreshSideTiles];
    UIView *old = _sideCurrentPage;
    UIView *root = _sideRootPage;
    _sideCurrentPage = root;
    [self installSidePage:root];
    CGFloat w = _sidePageHost.bounds.size.width;
    root.transform = CGAffineTransformMakeTranslation(-w * 0.3, 0);
    root.alpha = 0;
    [UIView animateWithDuration:0.22 animations:^{
        root.transform = CGAffineTransformIdentity;
        root.alpha = 1;
        old.transform = CGAffineTransformMakeTranslation(w, 0);
    } completion:^(BOOL f) {
        if (old != self->_sideCurrentPage) {
            [old removeFromSuperview];
        }
        old.transform = CGAffineTransformIdentity;
    }];
}

- (void)setSideTile:(UIButton *)b on:(BOOL)on title:(NSString *)title {
    UIButtonConfiguration *c = b.configuration;
    c.background.backgroundColor = on ? [UIColor.systemGreenColor colorWithAlphaComponent:0.55] : [UIColor colorWithWhite:1 alpha:0.1];
    if (title != nil) {
        c.title = title;
    }
    b.configuration = c;
}

- (void)refreshSideTiles {
    if (_statsTile == nil) {
        return;
    }
    BOOL absTouch = [_streamView isAbsoluteTouchMode];
    OnScreenControlsLevel lvl = [_streamView getCurrentOscState];
    [self setSideTile:_statsTile on:_statsMode != 0 title:nil];
    [self setSideTile:_oscTile on:lvl != OnScreenControlsLevelOff title:nil];
    [self setSideTile:_touchTile on:NO title:absTouch ? @"直接点击" : @"触控板"];
    _sideRowValues[@"stats"].text = @[@"关", @"详细", @"原版"][MIN(MAX(_statsMode, 0), 2)];
    NSString *oscName = @"自动";
    switch (lvl) {
        case OnScreenControlsLevelOff: oscName = @"关"; break;
        case OnScreenControlsLevelSimple: oscName = @"简易"; break;
        case OnScreenControlsLevelFull: oscName = @"完整"; break;
        default: break;
    }
    _sideRowValues[@"osc"].text = oscName;
    _sideRowValues[@"touch"].text = absTouch ? @"直接点击" : @"触控板";
    _sideRowValues[@"quality"].text = [self qualitySummary];
    [self syncQualityGroups];
    _sideRowValues[@"combo"].text = _customCombos.count ? [NSString stringWithFormat:@"%lu 个自定义", (unsigned long)_customCombos.count] : nil;
    _statsSegment.selectedSegmentIndex = _statsMode;
    _touchSegment.selectedSegmentIndex = absTouch ? 1 : 0;
    [self syncOscSegment];
}

- (void)refreshSideClock {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm";
    UIDevice *dev = UIDevice.currentDevice;
    dev.batteryMonitoringEnabled = YES;
    NSString *s = [f stringFromDate:[NSDate date]];
    if (dev.batteryLevel >= 0) {
        s = [s stringByAppendingFormat:@"  电量 %d%%", (int)lroundf(dev.batteryLevel * 100)];
    }
    _sideClockLabel.text = s;
}

- (void)statsTileTapped {
    [self setStatsMode:_statsMode != 0 ? 0 : (_lastStatsMode != 0 ? _lastStatsMode : 1)];
}

- (void)statsTileLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        [self pushSidePage:@"stats"];
    }
}

- (void)oscTileTapped {
    OnScreenControlsLevel cur = [_streamView getCurrentOscState];
    if (cur != OnScreenControlsLevelOff) {
        _lastOscLevel = cur;
        [_streamView setOnScreenControlsLevel:OnScreenControlsLevelOff];
    } else {
        [_streamView setOnScreenControlsLevel:_lastOscLevel == OnScreenControlsLevelSimple ? OnScreenControlsLevelSimple : OnScreenControlsLevelFull];
    }
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self refreshSideTiles];
}

- (void)oscTileLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        [self pushSidePage:@"osc"];
    }
}

- (void)touchTileTapped {
    [_streamView setAbsoluteTouchMode:![_streamView isAbsoluteTouchMode]];
    [self refreshSideTiles];
}

- (void)addComboSectionsToStack:(UIStackView *)stack {
    [self addCustomComboSectionToStack:stack];
    // { section title, @[ @[label, @[vk...]], ... ] }
    NSArray *sections = @[
        @[@"窗口", @[
            @[@"资源管理器", @[@VK_WIN, @0x45]],
            @[@"显示桌面", @[@VK_WIN, @0x44]],
            @[@"开始菜单", @[@VK_WIN]],
            @[@"任务视图", @[@VK_WIN, @0x09]],
            @[@"切换窗口", @[@VK_ALT, @0x09]],
            @[@"关闭窗口", @[@VK_ALT, @0x73]],
            @[@"任务管理器", @[@VK_CTRL, @VK_SHIFT, @0x1B]],
            @[@"运行", @[@VK_WIN, @0x52]],
            @[@"设置", @[@VK_WIN, @0x49]],
            @[@"截图", @[@VK_WIN, @VK_SHIFT, @0x53]],
            @[@"全屏切换", @[@VK_ALT, @0x0D]],
            @[@"最大化", @[@VK_WIN, @0x26]],
        ]],
        @[@"编辑", @[
            @[@"复制", @[@VK_CTRL, @0x43]],
            @[@"粘贴", @[@VK_CTRL, @0x56]],
            @[@"剪切", @[@VK_CTRL, @0x58]],
            @[@"撤销", @[@VK_CTRL, @0x5A]],
            @[@"全选", @[@VK_CTRL, @0x41]],
            @[@"保存", @[@VK_CTRL, @0x53]],
        ]],
        @[@"按键", @[
            @[@"Esc", @[@0x1B]],
            @[@"Enter", @[@0x0D]],
            @[@"Tab", @[@0x09]],
            @[@"Delete", @[@0x2E]],
            @[@"F5", @[@0x74]],
            @[@"F11", @[@0x7A]],
        ]],
    ];

    NSMutableArray *all = [NSMutableArray array];
    for (NSArray *section in sections) {
        UILabel *label = [[UILabel alloc] init];
        label.text = section[0];
        label.font = [UIFont systemFontOfSize:13];
        label.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        [stack addArrangedSubview:label];
        [stack setCustomSpacing:6 afterView:label];

        NSArray *items = section[1];
        UIStackView *row = nil;
        for (NSUInteger i = 0; i < items.count; i++) {
            if (i % 3 == 0) {
                row = [[UIStackView alloc] init];
                row.axis = UILayoutConstraintAxisHorizontal;
                row.distribution = UIStackViewDistributionFillEqually;
                row.spacing = 6;
                [stack addArrangedSubview:row];
                [stack setCustomSpacing:6 afterView:row];
            }
            UIButton *b = [self comboButton:items[i][0]];
            b.tag = all.count;
            [all addObject:items[i][1]];
            [b addTarget:self action:@selector(comboTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:b];
        }
        // pad the last row so buttons keep equal width
        while (row.arrangedSubviews.count < 3) {
            [row addArrangedSubview:[[UIView alloc] init]];
        }
        [stack setCustomSpacing:16 afterView:row];
    }
    _comboKeys = all;
}

static NSString *const kCustomCombosKey = @"moonlight.customCombos";

static NSNumber *vkForToken(NSString *t) {
    NSDictionary *named = @{@"ctrl": @VK_CTRL, @"control": @VK_CTRL, @"shift": @VK_SHIFT, @"alt": @VK_ALT,
                            @"win": @VK_WIN, @"meta": @VK_WIN, @"cmd": @VK_WIN,
                            @"esc": @0x1B, @"enter": @0x0D, @"tab": @0x09, @"space": @0x20,
                            @"del": @0x2E, @"delete": @0x2E, @"backspace": @0x08, @"bs": @0x08,
                            @"up": @0x26, @"down": @0x28, @"left": @0x25, @"right": @0x27,
                            @"home": @0x24, @"end": @0x23, @"pgup": @0x21, @"pgdn": @0x22,
                            @"ins": @0x2D, @"insert": @0x2D, @"prtsc": @0x2C};
    NSNumber *n = named[t];
    if (n != nil) {
        return n;
    }
    if (t.length == 1) {
        unichar c = [t.uppercaseString characterAtIndex:0];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
            return @(c);
        }
    }
    if (t.length >= 2 && [t hasPrefix:@"f"]) {
        int f = [[t substringFromIndex:1] intValue];
        if (f >= 1 && f <= 24) {
            return @(0x70 + f - 1);
        }
    }
    return nil;
}

static NSArray<NSNumber *> *parseComboSpec(NSString *spec) {
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *raw in [spec.lowercaseString componentsSeparatedByString:@"+"]) {
        NSString *t = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSNumber *vk = t.length ? vkForToken(t) : nil;
        if (vk == nil) {
            return nil;
        }
        [keys addObject:vk];
    }
    return keys.count ? keys : nil;
}

- (UIButton *)comboButton:(NSString *)title {
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = title;
    cfg.baseForegroundColor = UIColor.whiteColor;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 2, 8, 2);
    cfg.background.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    cfg.background.cornerRadius = 10;
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attrs) {
        NSMutableDictionary *m = [attrs mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        return m;
    };
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    [b.heightAnchor constraintEqualToConstant:42].active = YES;
    return b;
}

- (void)addCustomComboSectionToStack:(UIStackView *)stack {
    _customCombos = [[[NSUserDefaults standardUserDefaults] arrayForKey:kCustomCombosKey] mutableCopy] ?: [NSMutableArray array];
    UILabel *label = [[UILabel alloc] init];
    label.text = @"自定义（长按删除）";
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    [stack addArrangedSubview:label];
    [stack setCustomSpacing:6 afterView:label];
    _customComboStack = [[UIStackView alloc] init];
    _customComboStack.axis = UILayoutConstraintAxisVertical;
    _customComboStack.spacing = 6;
    [stack addArrangedSubview:_customComboStack];
    [stack setCustomSpacing:16 afterView:_customComboStack];
    [self rebuildCustomCombos];
}

- (void)rebuildCustomCombos {
    for (UIView *v in _customComboStack.arrangedSubviews) {
        [v removeFromSuperview];
    }
    NSUInteger count = _customCombos.count + 1;
    UIStackView *row = nil;
    for (NSUInteger i = 0; i < count; i++) {
        if (i % 3 == 0) {
            row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.distribution = UIStackViewDistributionFillEqually;
            row.spacing = 6;
            [_customComboStack addArrangedSubview:row];
        }
        UIButton *b;
        if (i < _customCombos.count) {
            b = [self comboButton:_customCombos[i][@"name"]];
            b.tag = i;
            [b addTarget:self action:@selector(customComboTapped:) forControlEvents:UIControlEventTouchUpInside];
            [b addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(customComboLongPressed:)]];
        } else {
            b = [self comboButton:@"+ 添加"];
            [b addTarget:self action:@selector(addCustomComboTapped) forControlEvents:UIControlEventTouchUpInside];
        }
        [row addArrangedSubview:b];
    }
    while (row.arrangedSubviews.count < 3) {
        [row addArrangedSubview:[[UIView alloc] init]];
    }
}

- (void)saveCustomCombos {
    [[NSUserDefaults standardUserDefaults] setObject:_customCombos forKey:kCustomCombosKey];
}

- (void)customComboTapped:(UIButton *)sender {
    [self sendCombo:_customCombos[sender.tag][@"keys"]];
}

- (void)customComboLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) {
        return;
    }
    NSInteger idx = g.view.tag;
    if (idx >= (NSInteger)_customCombos.count) {
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"删除「%@」？", _customCombos[idx][@"name"]]
                                                               message:_customCombos[idx][@"spec"]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [self->_customCombos removeObjectAtIndex:idx];
        [self saveCustomCombos];
        [self rebuildCustomCombos];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)addCustomComboTapped {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"添加组合键"
                                                               message:@"按键用 + 连接，例如 ctrl+shift+t、win+v、alt+f4、f2"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"名称（可空）";
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"ctrl+shift+t";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *wa = a;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
        NSString *name = [wa.textFields[0].text stringByTrimmingCharactersInSet:ws];
        NSString *spec = [wa.textFields[1].text stringByTrimmingCharactersInSet:ws];
        NSArray *keys = parseComboSpec(spec);
        if (keys == nil) {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"认不出这个组合键"
                                                                         message:spec.length ? spec : @"（空）"
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:err animated:YES completion:nil];
            return;
        }
        [self->_customCombos addObject:@{@"name": name.length ? name : spec, @"spec": spec, @"keys": keys}];
        [self saveCustomCombos];
        [self rebuildCustomCombos];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

static char modifierForVk(short vk) {
    switch (vk) {
        case VK_WIN: return MODIFIER_META;
        case VK_CTRL: return MODIFIER_CTRL;
        case VK_ALT: return MODIFIER_ALT;
        case VK_SHIFT: return MODIFIER_SHIFT;
        default: return 0;
    }
}

- (void)comboTapped:(UIButton *)sender {
    [self sendCombo:_comboKeys[sender.tag]];
}

- (void)sendCombo:(NSArray<NSNumber *> *)keys {
    [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight].impactOccurred;
    [self closeSidePanel];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Let the panel close animation start before the host reacts
        usleep(150 * 1000);
        char mods = 0;
        for (NSNumber *k in keys) {
            short vk = k.shortValue;
            mods |= modifierForVk(vk);
            LiSendKeyboardEvent(vk, KEY_ACTION_DOWN, mods);
            usleep(20 * 1000);
        }
        usleep(50 * 1000);
        for (NSNumber *k in keys.reverseObjectEnumerator) {
            short vk = k.shortValue;
            LiSendKeyboardEvent(vk, KEY_ACTION_UP, mods);
            mods &= ~modifierForVk(vk);
            usleep(20 * 1000);
        }
    });
}

- (UIButton *)sidePanelButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButtonConfiguration *cfg = [UIButtonConfiguration grayButtonConfiguration];
    cfg.title = title;
    cfg.image = [UIImage systemImageNamed:symbol];
    cfg.imagePadding = 10;
    cfg.baseForegroundColor = UIColor.whiteColor;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    return b;
}

- (CGFloat)sidePanelWidth {
    return MIN(300, self.view.bounds.size.width * 0.8) + self.view.safeAreaInsets.right;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_sidePanel == nil) {
        return;
    }
    CGSize s = self.view.bounds.size;
    CGFloat pw = [self sidePanelWidth];
    _sideHandle.frame = CGRectMake(s.width - kSideHandleWidth, (s.height - kSideHandleHeight) / 2, kSideHandleWidth, kSideHandleHeight);
    _sideDim.frame = self.view.bounds;
    _sidePanel.frame = CGRectMake(_sidePanelOpen ? s.width - pw : s.width, 0, pw, s.height);
}

- (void)sidePanStarted:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self openSidePanel];
    }
}

- (void)syncOscSegment {
    switch ([_streamView getCurrentOscState]) {
        case OnScreenControlsLevelOff: _oscSegment.selectedSegmentIndex = 0; break;
        case OnScreenControlsLevelSimple: _oscSegment.selectedSegmentIndex = 1; break;
        case OnScreenControlsLevelFull: _oscSegment.selectedSegmentIndex = 2; break;
        default: _oscSegment.selectedSegmentIndex = UISegmentedControlNoSegment; break;
    }
}

- (void)openSidePanel {
    if (_sidePanelOpen) {
        return;
    }
    _sidePanelOpen = YES;
    [self refreshSideTiles];
    [self refreshSideClock];
    [self.view bringSubviewToFront:_sideDim];
    [self.view bringSubviewToFront:_sidePanel];
    _sideDim.hidden = NO;
    _sidePanel.hidden = NO;
    CGSize s = self.view.bounds.size;
    CGFloat pw = [self sidePanelWidth];
    _sidePanel.frame = CGRectMake(s.width, 0, pw, s.height);
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:0 animations:^{
        self->_sidePanel.frame = CGRectMake(s.width - pw, 0, pw, s.height);
        self->_sideDim.alpha = 1;
        self->_sideHandle.alpha = 0;
    } completion:nil];
}

- (void)closeSidePanel {
    if (!_sidePanelOpen) {
        return;
    }
    _sidePanelOpen = NO;
    CGSize s = self.view.bounds.size;
    CGFloat pw = [self sidePanelWidth];
    [UIView animateWithDuration:0.2 animations:^{
        self->_sidePanel.frame = CGRectMake(s.width, 0, pw, s.height);
        self->_sideDim.alpha = 0;
        self->_sideHandle.alpha = 1;
    } completion:^(BOOL finished) {
        if (!self->_sidePanelOpen) {
            self->_sidePanel.hidden = YES;
            self->_sideDim.hidden = YES;
        }
    }];
}

- (void)oscSegmentChanged:(UISegmentedControl *)seg {
    OnScreenControlsLevel level = OnScreenControlsLevelOff;
    if (seg.selectedSegmentIndex == 1) {
        level = OnScreenControlsLevelSimple;
    } else if (seg.selectedSegmentIndex == 2) {
        level = OnScreenControlsLevelFull;
    }
    [_streamView setOnScreenControlsLevel:level];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self refreshSideTiles];
}

- (void)sideKeyboardTapped {
    [self closeSidePanel];
    [_streamView toggleKeyboard];
}

- (void)statsSegmentChanged:(UISegmentedControl *)seg {
    [self setStatsMode:seg.selectedSegmentIndex];
}

static NSString *const kStatsItemsKey = @"moonlight.statsItems";

static NSArray<NSArray<NSString *> *> *statsItemDefs(void) {
    return @[@[@"res", @"分辨率"], @[@"fps", @"帧率"], @[@"codec", @"编码"],
             @[@"bitrate", @"码率"], @[@"net", @"网络延迟"], @[@"loss", @"丢帧"],
             @[@"recv", @"接收耗时"], @[@"queue", @"解码排队"], @[@"host", @"主机处理"]];
}

- (UIStackView *)statsItemGrid {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kStatsItemsKey];
    _statsItemsOn = [NSMutableSet setWithArray:saved ?: @[@"res", @"fps", @"net", @"loss", @"bitrate"]];
    _statsItemButtons = [NSMutableArray array];
    UIStackView *grid = [[UIStackView alloc] init];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 6;
    NSArray *defs = statsItemDefs();
    UIStackView *row = nil;
    for (NSUInteger i = 0; i < defs.count; i++) {
        if (i % 3 == 0) {
            row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.distribution = UIStackViewDistributionFillEqually;
            row.spacing = 6;
            [grid addArrangedSubview:row];
        }
        UIButton *b = [self comboButton:defs[i][1]];
        b.tag = i;
        [b addTarget:self action:@selector(statsItemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_statsItemButtons addObject:b];
        [row addArrangedSubview:b];
    }
    [self refreshStatsItemButtons];
    return grid;
}

- (void)refreshStatsItemButtons {
    NSArray *defs = statsItemDefs();
    for (UIButton *b in _statsItemButtons) {
        BOOL on = [_statsItemsOn containsObject:defs[b.tag][0]];
        UIButtonConfiguration *cfg = b.configuration;
        cfg.background.backgroundColor = on ? UIColor.systemBlueColor : [UIColor colorWithWhite:1 alpha:0.12];
        b.configuration = cfg;
    }
}

- (void)statsItemTapped:(UIButton *)sender {
    NSString *key = statsItemDefs()[sender.tag][0];
    if ([_statsItemsOn containsObject:key]) {
        [_statsItemsOn removeObject:key];
    } else {
        [_statsItemsOn addObject:key];
    }
    [[NSUserDefaults standardUserDefaults] setObject:_statsItemsOn.allObjects forKey:kStatsItemsKey];
    [self refreshStatsItemButtons];
    if (_statsMode != 1) {
        _statsSegment.selectedSegmentIndex = 1;
        [self setStatsMode:1];
    } else {
        [self updateStatsOverlay];
    }
}

- (void)touchSegmentChanged:(UISegmentedControl *)seg {
    [_streamView setAbsoluteTouchMode:seg.selectedSegmentIndex == 1];
    [self refreshSideTiles];
}

- (void)setStatsMode:(NSInteger)mode {
    _statsMode = mode;
    if (mode != 0) {
        _lastStatsMode = mode;
    }
    [self refreshSideTiles];
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    [_overlayView setHidden:YES];
    _compactStatsLabel.hidden = YES;
    if (mode == 0) {
        return;
    }
    _statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                         target:self
                                                       selector:@selector(updateStatsOverlay)
                                                       userInfo:nil
                                                        repeats:YES];
    [self updateStatsOverlay];
}

- (void)updateCompactStats:(NSString *)text {
    if (_compactStatsLabel == nil) {
        _compactStatsLabel = [[UILabel alloc] init];
        _compactStatsLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
        _compactStatsLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        _compactStatsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        _compactStatsLabel.numberOfLines = 0;
        _compactStatsLabel.layer.cornerRadius = 6;
        _compactStatsLabel.clipsToBounds = YES;
        _compactStatsLabel.userInteractionEnabled = NO;
        [self.view addSubview:_compactStatsLabel];
    }
    if (text == nil) {
        // Keep the box visible so "no stats yet" is distinguishable from "overlay broken"
        text = @"等待统计数据…";
    }
    _compactStatsLabel.hidden = NO;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.firstLineHeadIndent = 7;
    ps.headIndent = 7;
    ps.lineSpacing = 2;
    _compactStatsLabel.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{NSParagraphStyleAttributeName: ps}];
    UIEdgeInsets inset = self.view.safeAreaInsets;
    CGSize sz = [_compactStatsLabel sizeThatFits:CGSizeMake(self.view.bounds.size.width / 2, CGFLOAT_MAX)];
    _compactStatsLabel.frame = CGRectMake(inset.left + 8, inset.top + 4, sz.width + 14, sz.height + 8);
    [self.view bringSubviewToFront:_compactStatsLabel];
    if (_sidePanelOpen) {
        [self.view bringSubviewToFront:_sideDim];
        [self.view bringSubviewToFront:_sidePanel];
    }
}

- (void)sideDisconnectTapped {
    [self closeSidePanel];
    [self returnToMainFrame];
}

// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

@end
