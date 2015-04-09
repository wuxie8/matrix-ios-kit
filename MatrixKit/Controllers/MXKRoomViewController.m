/*
 Copyright 2015 OpenMarket Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#define MXKROOMVIEWCONTROLLER_DEFAULT_TYPING_TIMEOUT_SEC 10
#define MXKROOMVIEWCONTROLLER_MESSAGES_TABLE_MINIMUM_HEIGHT 50

#define MXKROOMVIEWCONTROLLER_BACK_PAGINATION_MAX_SCROLLING_OFFSET 100

#import "MXKRoomViewController.h"

#import <MediaPlayer/MediaPlayer.h>

#import "MXKRoomBubbleTableViewCell.h"
#import "MXKImageView.h"
#import "MXKEventDetailsView.h"

#import "MXKRoomInputToolbarViewWithSimpleTextView.h"

NSString *const kCmdChangeDisplayName = @"/nick";
NSString *const kCmdEmote = @"/me";
NSString *const kCmdJoinRoom = @"/join";
NSString *const kCmdKickUser = @"/kick";
NSString *const kCmdBanUser = @"/ban";
NSString *const kCmdUnbanUser = @"/unban";
NSString *const kCmdSetUserPowerLevel = @"/op";
NSString *const kCmdResetUserPowerLevel = @"/deop";

@interface MXKRoomViewController () {
    /**
     The data source providing UITableViewCells for the current room.
     */
    MXKRoomDataSource *roomDataSource;
    
    /**
     The input toolbar view.
     */
    MXKRoomInputToolbarView *inputToolbarView;
    
    /**
     Potential event details view.
     */
    MXKEventDetailsView *eventDetailsView;
    
    /**
     Current alert (if any).
     */
    MXKAlert *currentAlert;
    
    /**
     The keyboard view set when keyboard display animation is complete. This field is nil when keyboard is dismissed.
     */
    UIView *keyboardView;
    
    /**
     Boolean value used to scroll to bottom the bubble history at first display.
     */
    BOOL shouldScrollToBottomOnTableRefresh;
    
    /**
     YES if scrolling to bottom is in progress
     */
    BOOL isScrollingToBottom;
    
    /**
     Date of the last observed typing
     */
    NSDate *lastTypingDate;
    
    /**
     Local typing timout
     */
    NSTimer* typingTimer;
    
    /**
     YES when back pagination is in progress.
     */
    BOOL isBackPaginationInProgress;
    
    /**
     Store current number of bubbles before back pagination.
     */
    NSInteger backPaginationSavedBubblesNb;
    
    /**
     Store the height of the first bubble before back pagination.
     */
    CGFloat backPaginationSavedFirstBubbleHeight;

    /**
     Potential request in progress to join the selected room
     */
    MXHTTPOperation *joinRoomRequest;

    // Attachment handling
    MXKImageView *highResImageView;
    NSString *AVAudioSessionCategory;
    MPMoviePlayerController *videoPlayer;
    MPMoviePlayerController *tmpVideoPlayer;
    NSString *selectedVideoURL;
    NSString *selectedVideoCachePath;
}

@property (nonatomic) IBOutlet UITableView *bubblesTableView;
@property (nonatomic) IBOutlet UIView *roomInputToolbarContainer;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *bubblesTableViewBottomConstraint;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *roomInputToolbarContainerHeightConstraint;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *roomInputToolbarContainerBottomConstraint;

@end

@implementation MXKRoomViewController
@synthesize roomDataSource, inputToolbarView;

#pragma mark - Class methods

+ (UINib *)nib
{
    return [UINib nibWithNibName:NSStringFromClass([MXKRoomViewController class])
                          bundle:[NSBundle bundleForClass:[MXKRoomViewController class]]];
}

+ (instancetype)roomViewController
{
    return [[[self class] alloc] initWithNibName:NSStringFromClass([MXKRoomViewController class])
                                          bundle:[NSBundle bundleForClass:[MXKRoomViewController class]]];
}

#pragma mark -

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Check whether the view controller has been pushed via storyboard
    if (!_bubblesTableView) {
        // Instantiate view controller objects
        [[[self class] nib] instantiateWithOwner:self options:nil];
        
        // Adjust bottom constraint of the input toolbar container in order to take into account potential tabBar
        if ([NSLayoutConstraint respondsToSelector:@selector(deactivateConstraints:)]) {
            [NSLayoutConstraint deactivateConstraints:@[_roomInputToolbarContainerBottomConstraint]];
        } else {
            [self.view removeConstraint:_roomInputToolbarContainerBottomConstraint];
        }
        
        _roomInputToolbarContainerBottomConstraint = [NSLayoutConstraint constraintWithItem:self.bottomLayoutGuide
                                                                                  attribute:NSLayoutAttributeTop
                                                                                  relatedBy:NSLayoutRelationEqual
                                                                                     toItem:self.roomInputToolbarContainer
                                                                                  attribute:NSLayoutAttributeBottom
                                                                                 multiplier:1.0f
                                                                                   constant:0.0f];
        if ([NSLayoutConstraint respondsToSelector:@selector(activateConstraints:)]) {
            [NSLayoutConstraint activateConstraints:@[_roomInputToolbarContainerBottomConstraint]];
        } else {
            [self.view addConstraint:_roomInputToolbarContainerBottomConstraint];
        }
        [self.view setNeedsUpdateConstraints];
    }
    
    // Set default input toolbar view
    [self setRoomInputToolbarViewClass:MXKRoomInputToolbarViewWithSimpleTextView.class];
    
    // Scroll to bottom the bubble history at first display
    shouldScrollToBottomOnTableRefresh = YES;
    
    // Check whether a room source has been defined
    if (roomDataSource) {
        [self configureView];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    
    [super viewWillAppear:animated];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    
    [super viewWillDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
}

- (void)dealloc {
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];

    // Dispose of any resources that can be recreated.
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id <UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(coordinator.transitionDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!keyboardView) {
            [self updateMessageTextViewFrame];
        }
        // Cell width will be updated, force table refresh to take into account changes of message components
        [self.bubblesTableView reloadData];
    });
}

// The 2 following methods are deprecated since iOS 8
- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
    
    // Cell width will be updated, force table refresh to take into account changes of message components
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.bubblesTableView reloadData];
    });
}
- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    
    if (!keyboardView) {
        [self updateMessageTextViewFrame];
    }
}

- (void)updateMessageTextViewFrame {
    if (!keyboardView) {
        // Compute the visible area (tableview + toolbar)
        CGFloat visibleArea = self.view.frame.size.height - _bubblesTableView.contentInset.top - keyboardView.frame.size.height;
        // Deduce max height of the message text input by considering the minimum height of the table view.
        inputToolbarView.maxHeight = visibleArea - MXKROOMVIEWCONTROLLER_MESSAGES_TABLE_MINIMUM_HEIGHT;
    }
}

#pragma mark -

- (void)configureView {

    // Set up table delegates
    _bubblesTableView.delegate = self;
    _bubblesTableView.dataSource = roomDataSource;
    
    // Set up classes to use for cells
    [_bubblesTableView registerClass:[roomDataSource cellViewClassForCellIdentifier:kMXKRoomIncomingTextMsgBubbleTableViewCellIdentifier] forCellReuseIdentifier:kMXKRoomIncomingTextMsgBubbleTableViewCellIdentifier];
    [_bubblesTableView registerClass:[roomDataSource cellViewClassForCellIdentifier:kMXKRoomOutgoingTextMsgBubbleTableViewCellIdentifier] forCellReuseIdentifier:kMXKRoomOutgoingTextMsgBubbleTableViewCellIdentifier];
    [_bubblesTableView registerClass:[roomDataSource cellViewClassForCellIdentifier:kMXKRoomIncomingAttachmentBubbleTableViewCellIdentifier] forCellReuseIdentifier:kMXKRoomIncomingAttachmentBubbleTableViewCellIdentifier];
    [_bubblesTableView registerClass:[roomDataSource cellViewClassForCellIdentifier:kMXKRoomOutgoingAttachmentBubbleTableViewCellIdentifier] forCellReuseIdentifier:kMXKRoomOutgoingAttachmentBubbleTableViewCellIdentifier];
}

- (BOOL)isBubblesTableScrollViewAtTheBottom {
    
    // Check whether the most recent message is visible.
    // Compute the max vertical position visible according to contentOffset
    CGFloat maxPositionY = _bubblesTableView.contentOffset.y + (_bubblesTableView.frame.size.height - _bubblesTableView.contentInset.bottom);
    // Be a bit less retrictive, consider the table view at the bottom even if the most recent message is partially hidden
    maxPositionY += 30;
    BOOL isScrolledToBottom = (maxPositionY >= _bubblesTableView.contentSize.height);
    
    // Consider the table view at the bottom if a scrolling to bottom is in progress too
    return (isScrolledToBottom || isScrollingToBottom);
}

- (void)scrollBubblesTableViewToBottomAnimated:(BOOL)animated {
    
    if (_bubblesTableView.contentSize.height) {
        CGFloat visibleHeight = _bubblesTableView.frame.size.height - _bubblesTableView.contentInset.top - _bubblesTableView.contentInset.bottom;
        if (visibleHeight < _bubblesTableView.contentSize.height) {
            CGFloat wantedOffsetY = _bubblesTableView.contentSize.height - visibleHeight - _bubblesTableView.contentInset.top;
            CGFloat currentOffsetY = _bubblesTableView.contentOffset.y;
            if (wantedOffsetY != currentOffsetY) {
                isScrollingToBottom = YES;
                [_bubblesTableView setContentOffset:CGPointMake(0, wantedOffsetY) animated:animated];
            }
        }
    }
}

#pragma mark - Public API

- (void)displayRoom:(MXKRoomDataSource *)dataSource {
    
    if (dataSource) {
        roomDataSource = dataSource;
        roomDataSource.delegate = self;
        
        // Report the matrix session at view controller level to update UI according to session state
        self.mxSession = roomDataSource.mxSession;
        
        if (_bubblesTableView) {
            [self configureView];
        }
        
        // Check whether an initial back pagination is required to fill the bubbles table
        if (roomDataSource.state == MXKDataSourceStateReady && ![roomDataSource tableView:_bubblesTableView numberOfRowsInSection:0]) {
            [self triggerInitialBackPagination];
        }
    } else {
        roomDataSource = nil;
        self.mxSession = nil;
    }
}

- (void)destroy {
    
    [self hideAttachmentView];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (keyboardView) {
        // Remove keyboard view observers
        [keyboardView removeObserver:self forKeyPath:NSStringFromSelector(@selector(frame))];
        [keyboardView removeObserver:self forKeyPath:NSStringFromSelector(@selector(center))];
        keyboardView = nil;
    }
    
    _bubblesTableView.dataSource = nil;
    _bubblesTableView.delegate = nil;
    _bubblesTableView = nil;

    roomDataSource = nil;
    
    self.mxSession = nil;
    
    if (currentAlert) {
        [currentAlert dismiss:NO];
        currentAlert = nil;
    }
    
    if (eventDetailsView) {
        [eventDetailsView removeFromSuperview];
        eventDetailsView = nil;
    }
    
    if (inputToolbarView) {
        inputToolbarView.delegate = nil;
        [inputToolbarView removeFromSuperview];
    }
    
    [typingTimer invalidate];
    typingTimer = nil;

    if (joinRoomRequest) {
        [joinRoomRequest cancel];
        joinRoomRequest = nil;
    }
}

- (void)setRoomInputToolbarViewClass:(Class)roomInputToolbarViewClass {
    // Sanity check: accept only MXKRoomInputToolbarView classes or sub-classes
    NSParameterAssert([roomInputToolbarViewClass isSubclassOfClass:MXKRoomInputToolbarView.class]);
    
    // Remove potential toolbar
    if (inputToolbarView) {
        inputToolbarView.delegate = nil;
        
        if ([NSLayoutConstraint respondsToSelector:@selector(deactivateConstraints:)]) {
            [NSLayoutConstraint deactivateConstraints:inputToolbarView.constraints];
        } else {
            [_roomInputToolbarContainer removeConstraints:inputToolbarView.constraints];
        }
        [inputToolbarView removeFromSuperview];
    }

    if ([roomInputToolbarViewClass nib]) {
        inputToolbarView = [[roomInputToolbarViewClass nib] instantiateWithOwner:nil options:nil].firstObject;
    } else
    {
        inputToolbarView = [[roomInputToolbarViewClass alloc] init];
    }
    
    inputToolbarView.delegate = self;
    
    // Add the input toolbar view and define edge constraints
    [_roomInputToolbarContainer addSubview:inputToolbarView];
    [_roomInputToolbarContainer addConstraint:[NSLayoutConstraint constraintWithItem:_roomInputToolbarContainer
                                                                           attribute:NSLayoutAttributeBottom
                                                                           relatedBy:NSLayoutRelationEqual
                                                                              toItem:inputToolbarView
                                                                           attribute:NSLayoutAttributeBottom
                                                                          multiplier:1.0f
                                                                            constant:0.0f]];
    [_roomInputToolbarContainer addConstraint:[NSLayoutConstraint constraintWithItem:_roomInputToolbarContainer
                                                                           attribute:NSLayoutAttributeTop
                                                                           relatedBy:NSLayoutRelationEqual
                                                                              toItem:inputToolbarView
                                                                           attribute:NSLayoutAttributeTop
                                                                          multiplier:1.0f
                                                                            constant:0.0f]];
    [_roomInputToolbarContainer addConstraint:[NSLayoutConstraint constraintWithItem:_roomInputToolbarContainer
                                                                           attribute:NSLayoutAttributeLeading
                                                                           relatedBy:NSLayoutRelationEqual
                                                                              toItem:inputToolbarView
                                                                           attribute:NSLayoutAttributeLeading
                                                                          multiplier:1.0f
                                                                            constant:0.0f]];
    [_roomInputToolbarContainer addConstraint:[NSLayoutConstraint constraintWithItem:_roomInputToolbarContainer
                                                                           attribute:NSLayoutAttributeTrailing
                                                                           relatedBy:NSLayoutRelationEqual
                                                                              toItem:inputToolbarView
                                                                           attribute:NSLayoutAttributeTrailing
                                                                          multiplier:1.0f
                                                                            constant:0.0f]];
    [_roomInputToolbarContainer setNeedsUpdateConstraints];
}

#pragma mark - activity indicator

- (void)stopActivityIndicator {

    // Check membership state before stopping the loading wheel
    // If the user is only invited, auto-join the room
    if (roomDataSource.room.state.membership == MXMembershipInvite && !joinRoomRequest) {
        joinRoomRequest = [roomDataSource.room join:^{
            
            joinRoomRequest = nil;
            [self didMatrixSessionStateChange];
        } failure:^(NSError *error) {

            NSLog(@"[MXKRoomDataSource] Failed to join room (%@): %@", roomDataSource.room.state.displayname, error);

            joinRoomRequest = nil;

            // Show the error to the end user
            __weak typeof(self) weakSelf = self;
            currentAlert = [[MXKAlert alloc] initWithTitle:@"Error"
                                                   message:[NSString stringWithFormat:@"Failed to join room (%@): %@", roomDataSource.room.state.displayname, error]
                                                     style:MXKAlertStyleAlert];
            currentAlert.cancelButtonIndex = [currentAlert addActionWithTitle:@"OK" style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
                typeof(self) self = weakSelf;
                self->currentAlert = nil;
            }];

            [currentAlert showInViewController:self];
        }];
    }

    // Keep the loading wheel displayed while we are joining the room
    if (joinRoomRequest) {
        return;
    }

    // Check internal processes before stopping the loading wheel
    if (isBackPaginationInProgress) {
        // Keep activity indicator running
        return;
    }
    
    // Leave super decide
    [super stopActivityIndicator];
}

#pragma mark - Keyboard handling

- (void)onKeyboardWillShow:(NSNotification *)notif {
    
    // Get the keyboard size
    NSValue *rectVal = notif.userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect endRect = rectVal.CGRectValue;
    
    // IOS 8 triggers some unexpected keyboard events
    if ((endRect.size.height == 0) || (endRect.size.width == 0)) {
        return;
    }
    
    // Check screen orientation
    CGFloat keyboardHeight = (endRect.origin.y == 0) ? endRect.size.width : endRect.size.height;
    
    // Compute the new bottom constraint for the input toolbar view (Don't forget potential tabBar)
    CGFloat inputToolbarViewBottomConst = keyboardHeight - self.bottomLayoutGuide.length;
    
    // Compute the visible area (tableview + toolbar) at the end of animation
    CGFloat visibleArea = self.view.frame.size.height - _bubblesTableView.contentInset.top - keyboardHeight;
    // Deduce max height of the message text input by considering the minimum height of the table view.
    CGFloat maxTextHeight = visibleArea - MXKROOMVIEWCONTROLLER_MESSAGES_TABLE_MINIMUM_HEIGHT;
    
    // Get the animation info
    NSNumber *curveValue = [[notif userInfo] objectForKey:UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationCurve animationCurve = curveValue.intValue;
    
    // The duration is ignored but it is better to define it
    double animationDuration = [[[notif userInfo] objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    [UIView animateWithDuration:animationDuration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | (animationCurve << 16) animations:^{
        
        // Apply new constant
        _roomInputToolbarContainerBottomConstraint.constant = inputToolbarViewBottomConst;
        _bubblesTableViewBottomConstraint.constant = inputToolbarViewBottomConst + _roomInputToolbarContainerHeightConstraint.constant;
        
        // Force layout immediately to take into account new constraint
        [self.view layoutIfNeeded];
        
        // Update the text input frame
        inputToolbarView.maxHeight = maxTextHeight;
        
        // Scroll the tableview content
        [self scrollBubblesTableViewToBottomAnimated:NO];
    } completion:^(BOOL finished) {
        
        // Check whether the keyboard is still visible at the end of animation
        keyboardView = inputToolbarView.inputAccessoryView.superview;
        if (keyboardView) {
            // Add observers to detect keyboard drag down
            [keyboardView addObserver:self forKeyPath:NSStringFromSelector(@selector(frame)) options:0 context:nil];
            [keyboardView addObserver:self forKeyPath:NSStringFromSelector(@selector(center)) options:0 context:nil];
            
            // Remove UIKeyboardWillShowNotification observer to ignore this notification until keyboard is dismissed.
            // Note: UIKeyboardWillShowNotification may be triggered several times before keyboard is dismissed,
            // because the keyboard height is updated (switch to a Chinese keyboard for example).
            [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
        }
    }];
}

- (void)onKeyboardWillHide:(NSNotification *)notif {
    
    // Update keyboard view observer
    if (keyboardView) {
        // Restore UIKeyboardWillShowNotification observer
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
        
        // Remove keyboard view observers
        [keyboardView removeObserver:self forKeyPath:NSStringFromSelector(@selector(frame))];
        [keyboardView removeObserver:self forKeyPath:NSStringFromSelector(@selector(center))];
        keyboardView = nil;
    }
    
    // Get the animation info
    NSNumber *curveValue = [[notif userInfo] objectForKey:UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationCurve animationCurve = curveValue.intValue;
    
    // the duration is ignored but it is better to define it
    double animationDuration = [[[notif userInfo] objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    // animate the keyboard closing
    [UIView animateWithDuration:animationDuration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | (animationCurve << 16) animations:^{
        _roomInputToolbarContainerBottomConstraint.constant = 0;
        _bubblesTableViewBottomConstraint.constant = _roomInputToolbarContainerHeightConstraint.constant;
        [_roomInputToolbarContainer setNeedsUpdateConstraints];
    } completion:^(BOOL finished) {
    }];
}

- (void)dismissKeyboard {
    [inputToolbarView dismissKeyboard];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ((object == keyboardView) && ([keyPath isEqualToString:NSStringFromSelector(@selector(frame))] || [keyPath isEqualToString:NSStringFromSelector(@selector(center))])) {
        // Check whether the keyboard is still visible
        if (inputToolbarView.inputAccessoryView.superview) {
            // The keyboard view has been modified (Maybe the user drag it down), we update the input toolbar bottom constraint to adjust layout.
            
            // Compute keyboard height
            CGSize screenSize = [[UIScreen mainScreen] bounds].size;
            // on IOS 8, the screen size is oriented
            if ((NSFoundationVersionNumber <= NSFoundationVersionNumber_iOS_7_1) && UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation)) {
                screenSize = CGSizeMake(screenSize.height, screenSize.width);
            }
            CGFloat keyboardHeight = screenSize.height - keyboardView.frame.origin.y;
            
            // Deduce the bottom constraint for the input toolbar view (Don't forget the potential tabBar)
            CGFloat inputToolbarViewBottomConst = keyboardHeight - self.bottomLayoutGuide.length;
            // Check whether the keyboard is over the tabBar
            if (inputToolbarViewBottomConst < 0) {
                inputToolbarViewBottomConst = 0;
            }
            
            // Update toolbar constraint
            _roomInputToolbarContainerBottomConstraint.constant = inputToolbarViewBottomConst;
            _bubblesTableViewBottomConstraint.constant = inputToolbarViewBottomConst + _roomInputToolbarContainerHeightConstraint.constant;
            [_roomInputToolbarContainer setNeedsUpdateConstraints];
        }
    }
}

#pragma mark - Back pagination

- (void)triggerInitialBackPagination {
    
    // Trigger back pagination to fill all the screen
    [roomDataSource paginateBackMessagesToFillRect:self.view.frame success:nil failure:nil];
}

- (void)triggerBackPagination {
    
    // Store the current height of the first bubble (if any)
    backPaginationSavedFirstBubbleHeight = 0;
    backPaginationSavedBubblesNb = [roomDataSource tableView:_bubblesTableView numberOfRowsInSection:0];
    if (backPaginationSavedBubblesNb) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:0];
        backPaginationSavedFirstBubbleHeight = [self tableView:_bubblesTableView heightForRowAtIndexPath:indexPath];
    }
    isBackPaginationInProgress = YES;
    [self startActivityIndicator];
    
    // Trigger back pagination
    [roomDataSource paginateBackMessages:10 success:^{
        
        // We will scroll to bottom if the displayed content does not reach the bottom (after adding back pagination)
        BOOL shouldScrollToBottom = NO;
        CGFloat maxPositionY = self.bubblesTableView.contentOffset.y + (self.bubblesTableView.frame.size.height - self.bubblesTableView.contentInset.bottom);
        // Compute the height of the blank part at the bottom
        if (maxPositionY > self.bubblesTableView.contentSize.height) {
            CGFloat blankAreaHeight = maxPositionY - self.bubblesTableView.contentSize.height;
            // Scroll to bottom if this blank area is greater than max scrolling offet
            shouldScrollToBottom = (blankAreaHeight >= MXKROOMVIEWCONTROLLER_BACK_PAGINATION_MAX_SCROLLING_OFFSET);
        }
        
        CGFloat verticalOffset = 0;
        if (shouldScrollToBottom == NO) {
            NSInteger addedBubblesNb = [roomDataSource tableView:_bubblesTableView numberOfRowsInSection:0] - backPaginationSavedBubblesNb;
            if (addedBubblesNb >= 0) {
                
                // We will adjust the vertical offset in order to make visible only a few part of added messages (at the top of the table)
                NSIndexPath *indexPath;
                // Compute the cumulative height of the added messages
                for (NSUInteger index = 0; index < addedBubblesNb; index++) {
                    indexPath = [NSIndexPath indexPathForRow:index inSection:0];
                    verticalOffset += [self tableView:_bubblesTableView heightForRowAtIndexPath:indexPath];
                }
                
                // Add delta of the height of the first existing message
                indexPath = [NSIndexPath indexPathForRow:addedBubblesNb inSection:0];
                verticalOffset += ([self tableView:_bubblesTableView heightForRowAtIndexPath:indexPath] - backPaginationSavedFirstBubbleHeight);
                
                // Deduce the vertical offset from this height
                verticalOffset -= MXKROOMVIEWCONTROLLER_BACK_PAGINATION_MAX_SCROLLING_OFFSET;
            }
        }
        
        // Adjust vertical content offset
        if (shouldScrollToBottom) {
            [self scrollBubblesTableViewToBottomAnimated:NO];
        } else if (verticalOffset > 0) {
            // Adjust vertical offset in order to limit scrolling down
            CGPoint contentOffset = self.bubblesTableView.contentOffset;
            contentOffset.y = verticalOffset - self.bubblesTableView.contentInset.top;
            [self.bubblesTableView setContentOffset:contentOffset animated:NO];
        }
        
        // Reload table
        isBackPaginationInProgress = NO;
        [_bubblesTableView reloadData];
        [self stopActivityIndicator];
        
    }
                                 failure:^(NSError *error) {
                                     // Reload table
                                     isBackPaginationInProgress = NO;
                                     [_bubblesTableView reloadData];
                                     [self stopActivityIndicator];
                                 }];
}

#pragma mark - Post messages

- (BOOL)isIRCStyleCommand:(NSString*)string {
    
    // Check whether the provided text may be an IRC-style command
    if ([string hasPrefix:@"/"] == NO || [string hasPrefix:@"//"] == YES) {
        return NO;
    }
    
    // Parse command line
    NSArray *components = [string componentsSeparatedByString:@" "];
    NSString *cmd = [components objectAtIndex:0];
    NSUInteger index = 1;
    
    if ([cmd isEqualToString:kCmdEmote]) {
        // send message as an emote
        [self sendTextMessage:string];
    } else if ([string hasPrefix:kCmdChangeDisplayName]) {
        // Change display name
        NSString *displayName = [string substringFromIndex:kCmdChangeDisplayName.length + 1];
        // Remove white space from both ends
        displayName = [displayName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        if (displayName.length) {
            [roomDataSource.mxSession.matrixRestClient setDisplayName:displayName success:^{
            } failure:^(NSError *error) {
                NSLog(@"[MXKRoomVC] Set displayName failed: %@", error);
                // TODO Alert user
//                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
        } else {
            // Display cmd usage in text input as placeholder
            inputToolbarView.placeholder = @"Usage: /nick <display_name>";
        }
    } else if ([string hasPrefix:kCmdJoinRoom]) {
        // Join a room
        NSString *roomAlias = [string substringFromIndex:kCmdJoinRoom.length + 1];
        // Remove white space from both ends
        roomAlias = [roomAlias stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        // Check
        if (roomAlias.length) {
            [roomDataSource.mxSession joinRoom:roomAlias success:^(MXRoom *room) {
                // Do nothing by default when we succeed to join the room
            } failure:^(NSError *error) {
                NSLog(@"[MXKRoomVC] Join roomAlias (%@) failed: %@", roomAlias, error);
                // TODO Alert user
//                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
        } else {
            // Display cmd usage in text input as placeholder
            inputToolbarView.placeholder = @"Usage: /join <room_alias>";
        }
    } else {
        // Retrieve userId
        NSString *userId = nil;
        while (index < components.count) {
            userId = [components objectAtIndex:index++];
            if (userId.length) {
                // done
                break;
            }
            // reset
            userId = nil;
        }
        
        if ([cmd isEqualToString:kCmdKickUser]) {
            if (userId) {
                // Retrieve potential reason
                NSString *reason = nil;
                while (index < components.count) {
                    if (reason) {
                        reason = [NSString stringWithFormat:@"%@ %@", reason, [components objectAtIndex:index++]];
                    } else {
                        reason = [components objectAtIndex:index++];
                    }
                }
                // Kick the user
                [roomDataSource.room kickUser:userId reason:reason success:^{
                } failure:^(NSError *error) {
                    NSLog(@"[MXKRoomVC] Kick user (%@) failed: %@", userId, error);
                    // TODO Alert user
//                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                inputToolbarView.placeholder = @"Usage: /kick <userId> [<reason>]";
            }
        } else if ([cmd isEqualToString:kCmdBanUser]) {
            if (userId) {
                // Retrieve potential reason
                NSString *reason = nil;
                while (index < components.count) {
                    if (reason) {
                        reason = [NSString stringWithFormat:@"%@ %@", reason, [components objectAtIndex:index++]];
                    } else {
                        reason = [components objectAtIndex:index++];
                    }
                }
                // Ban the user
                [roomDataSource.room banUser:userId reason:reason success:^{
                } failure:^(NSError *error) {
                    NSLog(@"[MXKRoomVC] Ban user (%@) failed: %@", userId, error);
                    // TODO Alert user
//                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                inputToolbarView.placeholder = @"Usage: /ban <userId> [<reason>]";
            }
        } else if ([cmd isEqualToString:kCmdUnbanUser]) {
            if (userId) {
                // Unban the user
                [roomDataSource.room unbanUser:userId success:^{
                } failure:^(NSError *error) {
                    NSLog(@"[MXKRoomVC] Unban user (%@) failed: %@", userId, error);
                    // TODO Alert user
//                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                inputToolbarView.placeholder = @"Usage: /unban <userId>";
            }
        } else if ([cmd isEqualToString:kCmdSetUserPowerLevel]) {
            // Retrieve power level
            NSString *powerLevel = nil;
            while (index < components.count) {
                powerLevel = [components objectAtIndex:index++];
                if (powerLevel.length) {
                    // done
                    break;
                }
                // reset
                powerLevel = nil;
            }
            // Set power level
            if (userId && powerLevel) {
                // Set user power level
                [roomDataSource.room setPowerLevelOfUserWithUserID:userId powerLevel:[powerLevel integerValue] success:^{
                } failure:^(NSError *error) {
                    NSLog(@"[MXKRoomVC] Set user power (%@) failed: %@", userId, error);
                    // TODO Alert user
//                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                inputToolbarView.placeholder = @"Usage: /op <userId> <power level>";
            }
        } else if ([cmd isEqualToString:kCmdResetUserPowerLevel]) {
            if (userId) {
                // Reset user power level
                [roomDataSource.room setPowerLevelOfUserWithUserID:userId powerLevel:0 success:^{
                } failure:^(NSError *error) {
                    NSLog(@"[MXKRoomVC] Reset user power (%@) failed: %@", userId, error);
                    // TODO Alert user
//                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                inputToolbarView.placeholder = @"Usage: /deop <userId>";
            }
        } else {
            NSLog(@"[MXKRoomVC] Unrecognised IRC-style command: %@", string);
            inputToolbarView.placeholder = [NSString stringWithFormat:@"Unrecognised IRC-style command: %@", cmd];
        }
    }
    return YES;
}

- (void)sendTextMessage:(NSString*)msgTxt {

    // Let the datasource send it and manage the local echo
    [roomDataSource sendTextMessage:msgTxt success:nil failure:^(NSError *error) {

        // @TODO
        NSLog(@"[MXKRoomViewController] sendTextMessage failed. Error:%@", error);
    }];
}

# pragma mark - Event handling

- (void)showEventDetails:(MXEvent *)event {
    [self dismissKeyboard];
    
    // Remove potential existing view
    if (eventDetailsView) {
        [eventDetailsView removeFromSuperview];
    }
    eventDetailsView = [[MXKEventDetailsView alloc] initWithEvent:event andMatrixSession:roomDataSource.mxSession];
    
    // Add shadow on event details view
    eventDetailsView.layer.cornerRadius = 5;
    eventDetailsView.layer.shadowOffset = CGSizeMake(0, 1);
    eventDetailsView.layer.shadowOpacity = 0.5f;
    
    // Add the view and define edge constraints
    [self.view addSubview:eventDetailsView];
    
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:eventDetailsView
                                                          attribute:NSLayoutAttributeTop
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.topLayoutGuide
                                                          attribute:NSLayoutAttributeBottom
                                                         multiplier:1.0f
                                                           constant:10.0f]];
    
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:eventDetailsView
                                                          attribute:NSLayoutAttributeBottom
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.bottomLayoutGuide
                                                          attribute:NSLayoutAttributeTop
                                                         multiplier:1.0f
                                                           constant:-10.0f]];
    
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.view
                                                          attribute:NSLayoutAttributeLeading
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:eventDetailsView
                                                          attribute:NSLayoutAttributeLeading
                                                         multiplier:1.0f
                                                           constant:-10.0f]];
    
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.view
                                                          attribute:NSLayoutAttributeTrailing
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:eventDetailsView
                                                          attribute:NSLayoutAttributeTrailing
                                                         multiplier:1.0f
                                                           constant:10.0f]];
    [self.view setNeedsUpdateConstraints];    
}

- (void)promptUserToResendEvent:(NSString *)eventId {
    // TODO prompt User To Resend Event
    NSLog(@"[MXKRoomViewController] resend event is not supported yet (%@)", eventId);
}

#pragma mark - MXKDataSourceDelegate
- (void)dataSource:(MXKDataSource *)dataSource didCellChange:(id)changes {
    
    if (isBackPaginationInProgress) {
        // table will be updated at the end of pagination.
        return;
    }
    
    // We will scroll to bottom if the bottom of the table is currently visible
    BOOL shouldScrollToBottom = (shouldScrollToBottomOnTableRefresh || [self isBubblesTableScrollViewAtTheBottom]);
    
    // For now, do a simple full reload
    [_bubblesTableView reloadData];
    
    if (shouldScrollToBottom) {
        // Scroll to the bottom
        [self scrollBubblesTableViewToBottomAnimated:NO];
        shouldScrollToBottomOnTableRefresh = NO;
    }
}

- (void)dataSource:(MXKDataSource *)dataSource didStateChange:(MXKDataSourceState)state {
    
    if (state == MXKDataSourceStateReady && ![roomDataSource tableView:_bubblesTableView numberOfRowsInSection:0]) {
        [self triggerInitialBackPagination];
    }
}

- (void)dataSource:(MXKDataSource *)dataSource didRecognizeAction:(NSString *)actionIdentifier inCell:(id<MXKCellRendering>)cell userInfo:(NSDictionary *)userInfo {

    NSLog(@"Gesture %@ has been recognized in %@. UserInfo: %@", actionIdentifier, cell, userInfo);

    if ([actionIdentifier isEqualToString:kMXKRoomBubbleCellTapOnAvatarView]) {
        NSLog(@"    -> Avatar of %@ has been tapped", userInfo[kMXKRoomBubbleCellUserIdKey]);
    }
    else if ([actionIdentifier isEqualToString:kMXKRoomBubbleCellTapOnDateTimeContainer]) {
        MXKRoomBubbleTableViewCell *roomBubbleTableViewCell = (MXKRoomBubbleTableViewCell *)cell;
        BOOL newDateTimeLabelContainerHidden = !roomBubbleTableViewCell.dateTimeLabelContainer.hidden;

        NSLog(@"    -> Turn %@ cells date", newDateTimeLabelContainerHidden ? @"OFF" : @"ON");

        // @TODO: How to indicate MXKRoomBubbleTableViewCell cells they must not show date anymore
        // The only global object we pass to them is the event formatter but its jobs is converting MXEvents into texts.
        // It cannot be used to pass cells config.
        // If this VC implements its tableview datasource, it will be far easier. We could customise cells
        // just before providing them to the tableview.
    }
    else if ([actionIdentifier isEqualToString:kMXKRoomBubbleCellTapOnAttachmentView]) {
        MXKRoomBubbleTableViewCell *roomBubbleTableViewCell = (MXKRoomBubbleTableViewCell *)cell;
        [self showAttachmentView:roomBubbleTableViewCell.attachmentView];
    }
    else if ([actionIdentifier isEqualToString:kMXKRoomBubbleCellLongPressOnProgressView]) {
        MXKRoomBubbleTableViewCell *roomBubbleTableViewCell = (MXKRoomBubbleTableViewCell *)cell;
        
        // Check if there is a download in progress, then offer to cancel it
        NSString *cacheFilePath = roomBubbleTableViewCell.bubbleData.attachmentCacheFilePath;
        if ([MXKMediaManager existingDownloaderWithOutputFilePath:cacheFilePath]) {
            __weak typeof(self) weakSelf = self;
            currentAlert = [[MXKAlert alloc] initWithTitle:nil message:@"Cancel the download ?" style:MXKAlertStyleAlert];
            currentAlert.cancelButtonIndex = [currentAlert addActionWithTitle:@"Cancel" style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
                typeof(self) self = weakSelf;
                self->currentAlert = nil;
            }];
            currentAlert.cancelButtonIndex = [currentAlert addActionWithTitle:@"OK" style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
                typeof(self) self = weakSelf;
                // Get again the loader
                MXKMediaLoader *loader = [MXKMediaManager existingDownloaderWithOutputFilePath:cacheFilePath];
                if (loader) {
                    [loader cancel];
                }
                self->currentAlert = nil;
            }];
            
            [currentAlert showInViewController:self];
        }
    }
    else if ([actionIdentifier isEqualToString:kMXKRoomBubbleCellLongPressOnEvent]) {
        MXEvent *selectedEvent = userInfo[kMXKRoomBubbleCellEventKey];
        if (selectedEvent) {
            // Check status of the selected event
            if (selectedEvent.mxkState == MXKEventStateSendingFailed) {
                // The user may want to resend it
                [self promptUserToResendEvent:selectedEvent.eventId];
            } else if (selectedEvent.mxkState != MXKEventStateSending) {
                // Display event details
                [self showEventDetails:selectedEvent];
            }
        }
    } else if ([actionIdentifier isEqualToString:kMXKRoomBubbleCellUnsentButtonPressed]) {
        MXEvent *selectedEvent = userInfo[kMXKRoomBubbleCellEventKey];
        if (selectedEvent) {
            // The user may want to resend it
            [self promptUserToResendEvent:selectedEvent.eventId];
        }
    }
}

#pragma mark - UITableView delegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Compute here height of bubble cell
    CGFloat rowHeight;
    
    id<MXKRoomBubbleCellDataStoring> bubbleData = [roomDataSource cellDataAtIndex:indexPath.row];
    
    // Sanity check
    if (!bubbleData) {
        return 0;
    }
    
    Class cellViewClass;
    if (bubbleData.isIncoming) {
        if (bubbleData.isAttachment) {
            cellViewClass = [roomDataSource cellViewClassForCellIdentifier:kMXKRoomIncomingAttachmentBubbleTableViewCellIdentifier];
        } else {
            cellViewClass = [roomDataSource cellViewClassForCellIdentifier:kMXKRoomIncomingTextMsgBubbleTableViewCellIdentifier];
        }
    } else if (bubbleData.isAttachment) {
        cellViewClass = [roomDataSource cellViewClassForCellIdentifier:kMXKRoomOutgoingAttachmentBubbleTableViewCellIdentifier];
    } else {
        cellViewClass = [roomDataSource cellViewClassForCellIdentifier:kMXKRoomOutgoingTextMsgBubbleTableViewCellIdentifier];
    }
    
    rowHeight = [cellViewClass heightForCellData:bubbleData withMaximumWidth:tableView.frame.size.width];
    return rowHeight;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    
    // Dismiss keyboard when user taps on messages table view content
    [self dismissKeyboard];
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath*)indexPath {
    
    // Release here resources, and restore reusable cells
    if ([cell respondsToSelector:@selector(didEndDisplay)]) {
        [(id<MXKCellRendering>)cell didEndDisplay];
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    
    // Detect vertical bounce at the top of the tableview to trigger pagination
    if (scrollView == _bubblesTableView) {
        // paginate ?
        if (scrollView.contentOffset.y < -64) {
            [self triggerBackPagination];
        }
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    
    // Consider this callback to reset scrolling to bottom flag
    isScrollingToBottom = NO;
}

#pragma mark - MXKRoomInputToolbarViewDelegate

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView isTyping:(BOOL)typing {
    
    if (typing) {
        // Reset potential placeholder (used in case of wrong command usage)
        inputToolbarView.placeholder = nil;
    }
    [self handleTypingNotification:typing];
}

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView heightDidChanged:(CGFloat)height {
    _roomInputToolbarContainerHeightConstraint.constant = height;
    
    // Lays out the subviews immediately
    // We will scroll to bottom if the bottom of the table is currently visible
    BOOL shouldScrollToBottom = [self isBubblesTableScrollViewAtTheBottom];
    CGFloat bubblesTableViewBottomConst = _roomInputToolbarContainerBottomConstraint.constant + _roomInputToolbarContainerHeightConstraint.constant;
    if (_bubblesTableViewBottomConstraint.constant != bubblesTableViewBottomConst) {
        _bubblesTableViewBottomConstraint.constant = bubblesTableViewBottomConst;
        // Force to render the view
        [self.view layoutIfNeeded];
        if (shouldScrollToBottom) {
            [self scrollBubblesTableViewToBottomAnimated:NO];
        }
    }
}

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView sendTextMessage:(NSString*)textMessage {
    
    // Handle potential IRC commands in typed string
    if ([self isIRCStyleCommand:textMessage] == NO) {
        // Send text message in the current room
        [self sendTextMessage:textMessage];
    }
}

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView sendImage:(UIImage*)image {
    // Let the datasource send it and manage the local echo
    [roomDataSource sendImage:image success:nil failure:^(NSError *error) {
        // @TODO
        NSLog(@"[MXKRoomViewController] sendImage failed. Error:%@", error);
    }];

}

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView sendVideo:(NSURL*)videoURL withThumbnail:(UIImage*)videoThumbnail {
    // TODO
}

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView inviteMatrixUser:(NSString*)mxUserId {
    [roomDataSource.room inviteUser:mxUserId success:^{
    } failure:^(NSError *error) {
        NSLog(@"[MXKRoomVC] Invite %@ failed: %@", mxUserId, error);
        // TODO: Alert user
//        [[AppDelegate theDelegate] showErrorAsAlert:error];
    }];
}

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView presentMXKAlert:(MXKAlert*)alert {
    [alert showInViewController:self];
}

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView presentMediaPicker:(UIImagePickerController*)mediaPicker {
    [self presentViewController:mediaPicker animated:YES completion:nil];
}

- (void)roomInputToolbarView:(MXKRoomInputToolbarView*)toolbarView dismissMediaPicker:(UIImagePickerController*)mediaPicker {
    if (self.presentedViewController == mediaPicker) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }
}

# pragma mark - Typing notification

- (void)handleTypingNotification:(BOOL)typing {
    NSUInteger notificationTimeoutMS = -1;
    if (typing) {
        // Check whether a typing event has been already reported to server (We wait for the end of the local timout before considering this new event)
        if (typingTimer) {
            // Refresh date of the last observed typing
            lastTypingDate = [[NSDate alloc] init];
            return;
        }
        
        // Launch a timer to prevent sending multiple typing notifications
        NSTimeInterval timerTimeout = MXKROOMVIEWCONTROLLER_DEFAULT_TYPING_TIMEOUT_SEC;
        if (lastTypingDate) {
            NSTimeInterval lastTypingAge = -[lastTypingDate timeIntervalSinceNow];
            if (lastTypingAge < timerTimeout) {
                // Subtract the time interval since last typing from the timer timeout
                timerTimeout -= lastTypingAge;
            } else {
                timerTimeout = 0;
            }
        } else {
            // Keep date of this typing event
            lastTypingDate = [[NSDate alloc] init];
        }
        
        if (timerTimeout) {
            typingTimer = [NSTimer scheduledTimerWithTimeInterval:timerTimeout target:self selector:@selector(typingTimeout:) userInfo:self repeats:NO];
            // Compute the notification timeout in ms (consider the double of the local typing timeout)
            notificationTimeoutMS = 2000 * MXKROOMVIEWCONTROLLER_DEFAULT_TYPING_TIMEOUT_SEC;
        } else {
            // This typing event is too old, we will ignore it
            typing = NO;
            NSLog(@"[MXKRoomVC] Ignore typing event (too old)");
        }
    } else {
        // Cancel any typing timer
        [typingTimer invalidate];
        typingTimer = nil;
        // Reset last typing date
        lastTypingDate = nil;
    }
    
    // Send typing notification to server
    [roomDataSource.room sendTypingNotification:typing
                                timeout:notificationTimeoutMS
                                success:^{
                                    // Reset last typing date
                                    lastTypingDate = nil;
                                } failure:^(NSError *error) {
                                    NSLog(@"[MXKRoomVC] Failed to send typing notification (%d) failed: %@", typing, error);
                                    // Cancel timer (if any)
                                    [typingTimer invalidate];
                                    typingTimer = nil;
                                }];
}

- (IBAction)typingTimeout:(id)sender {
    [typingTimer invalidate];
    typingTimer = nil;
    
    // Check whether a new typing event has been observed
    BOOL typing = (lastTypingDate != nil);
    // Post a new typing notification
    [self handleTypingNotification:typing];
}


# pragma mark - Attachment handling

- (void)showAttachmentView:(MXKImageView *)attachment {

    [self dismissKeyboard];

    // Retrieve attachment information
    NSDictionary *content = attachment.mediaInfo;
    NSUInteger msgtype = ((NSNumber*)content[@"msgtype"]).unsignedIntValue;
    if (msgtype == MXKRoomBubbleCellDataTypeImage) {
        NSString *url = content[@"url"];
        if (url.length) {

           // Use another MXKImageView that will show the fullscreen image URL in fullscreen
            highResImageView = [[MXKImageView alloc] initWithFrame:self.view.frame];
            highResImageView.stretchable = YES;
            highResImageView.mediaFolder = roomDataSource.roomId;
            [highResImageView setImageURL:url withImageOrientation:UIImageOrientationUp andPreviewImage:attachment.image];
            [highResImageView showFullScreen];

            // Add tap recognizer to hide attachment
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideAttachmentView)];
            [tap setNumberOfTouchesRequired:1];
            [tap setNumberOfTapsRequired:1];
            [highResImageView addGestureRecognizer:tap];
            highResImageView.userInteractionEnabled = YES;
        }
    } else if (msgtype == MXKRoomBubbleCellDataTypeVideo) {
        NSString *url =content[@"url"];
        if (url.length) {
            NSString *mimetype = nil;
            if (content[@"info"]) {
                mimetype = content[@"info"][@"mimetype"];
            }
            AVAudioSessionCategory = [[AVAudioSession sharedInstance] category];
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
            videoPlayer = [[MPMoviePlayerController alloc] init];
            if (videoPlayer != nil) {
                videoPlayer.scalingMode = MPMovieScalingModeAspectFit;
                [self.view addSubview:videoPlayer.view];
                [videoPlayer setFullscreen:YES animated:NO];
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(moviePlayerPlaybackDidFinishNotification:)
                                                             name:MPMoviePlayerPlaybackDidFinishNotification
                                                           object:nil];
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(moviePlayerWillExitFullscreen:)
                                                             name:MPMoviePlayerWillExitFullscreenNotification
                                                           object:videoPlayer];
                selectedVideoURL = url;

                // check if the file is a local one
                // could happen because a media upload has failed
                if ([[NSFileManager defaultManager] fileExistsAtPath:selectedVideoURL]) {
                    selectedVideoCachePath = selectedVideoURL;
                } else {
                    selectedVideoCachePath = [MXKMediaManager cachePathForMediaWithURL:selectedVideoURL andType:mimetype inFolder:roomDataSource.roomId];
                }

                if ([[NSFileManager defaultManager] fileExistsAtPath:selectedVideoCachePath]) {
                    videoPlayer.contentURL = [NSURL fileURLWithPath:selectedVideoCachePath];
                    [videoPlayer play];
                } else {
                    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onMediaDownloadEnd:) name:kMXKMediaDownloadDidFinishNotification object:nil];
                    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onMediaDownloadEnd:) name:kMXKMediaDownloadDidFailNotification object:nil];

                    NSString *localFilePath = [MXKMediaManager cachePathForMediaWithURL:selectedVideoURL andType:mimetype inFolder:roomDataSource.roomId];
                    [MXKMediaManager downloadMediaFromURL:selectedVideoURL andSaveAtFilePath:localFilePath];
                }
            }
        }
    } else if (msgtype == MXKRoomBubbleCellDataTypeAudio) {
    } else if (msgtype == MXKRoomBubbleCellDataTypeLocation) {
    }
}

- (void)onMediaDownloadEnd:(NSNotification *)notif {
    if ([notif.object isKindOfClass:[NSString class]]) {
        NSString* url = notif.object;
        if ([url isEqualToString:selectedVideoURL]) {
            // remove the observers
            [[NSNotificationCenter defaultCenter] removeObserver:self name:kMXKMediaDownloadDidFinishNotification object:nil];
            [[NSNotificationCenter defaultCenter] removeObserver:self name:kMXKMediaDownloadDidFailNotification object:nil];

            if ([[NSFileManager defaultManager] fileExistsAtPath:selectedVideoCachePath]) {
                videoPlayer.contentURL = [NSURL fileURLWithPath:selectedVideoCachePath];
                [videoPlayer play];
            } else {
                NSLog(@"[RoomVC] Video Download failed"); // TODO we should notify user
                [self hideAttachmentView];
            }
        }
    }
}

- (void)hideAttachmentView {

    selectedVideoURL = nil;
    selectedVideoCachePath = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MPMoviePlayerPlaybackDidFinishNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MPMoviePlayerWillExitFullscreenNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kMXKMediaDownloadDidFinishNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kMXKMediaDownloadDidFailNotification object:nil];

    if (highResImageView) {
        [highResImageView removeFromSuperview];
        highResImageView = nil;
    }

    // Restore audio category
    if (AVAudioSessionCategory) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategory error:nil];
    }
    if (videoPlayer) {
        [videoPlayer stop];
        [videoPlayer setFullscreen:NO];
        [videoPlayer.view removeFromSuperview];
        videoPlayer = nil;
    }
}

- (void)moviePlayerWillExitFullscreen:(NSNotification*)notification {
    if (notification.object == videoPlayer) {
        [self hideAttachmentView];
    }
}

- (void)moviePlayerPlaybackDidFinishNotification:(NSNotification *)notification {
    NSDictionary *notificationUserInfo = [notification userInfo];
    NSNumber *resultValue = [notificationUserInfo objectForKey:MPMoviePlayerPlaybackDidFinishReasonUserInfoKey];
    MPMovieFinishReason reason = [resultValue intValue];

    // error cases
    if (reason == MPMovieFinishReasonPlaybackError) {
        NSError *mediaPlayerError = [notificationUserInfo objectForKey:@"error"];
        if (mediaPlayerError) {
            NSLog(@"[RoomVC] Playback failed with error description: %@", [mediaPlayerError localizedDescription]);
            [self hideAttachmentView];
            //Alert user
            // @TODO [[AppDelegate theDelegate] showErrorAsAlert:mediaPlayerError];
        }
    }
}

@end
