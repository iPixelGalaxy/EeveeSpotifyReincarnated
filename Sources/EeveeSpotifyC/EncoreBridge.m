#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Tweak.h"

UIImage *EeveeRenderTemplate(UIView *view) {
    CGSize size = view.bounds.size;
    if (size.width < 2 || size.height < 2) return nil;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [view.layer renderInContext:context.CGContext];
    }];
    CGImageRef cg = image.CGImage;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    NSMutableData *alpha = [NSMutableData dataWithLength:width * height];
    CGContextRef context = CGBitmapContextCreate(alpha.mutableBytes, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
    CGContextRelease(context);
    const uint8_t *bytes = alpha.bytes;
    for (size_t i = 0; i < alpha.length; i++) {
        if (bytes[i] > 16) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

UIImage *EeveeEncoreIconImage(UIView *live, BOOL active) {
    CGSize size = live.bounds.size;
    Ivar ivar = class_getInstanceVariable(live.class, "icon");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    id icon = type && type[0] == '@' ? object_getIvar(live, ivar) : nil;
    Class viewClass = NSClassFromString(@"SPTEncoreIconView");
    if (!icon || !viewClass || size.width < 2) return nil;

    UIView *view = ((id (*)(id, SEL, id))objc_msgSend)([viewClass alloc], @selector(initWithIcon:), icon);
    view.frame = (CGRect){CGPointZero, size};
    SEL setters[] = {@selector(setForegroundColor:), NSSelectorFromString(@"setActiveForegroundColor:")};
    for (int i = 0; i < 2; i++) {
        if ([view respondsToSelector:setters[i]]) ((void (*)(id, SEL, id))objc_msgSend)(view, setters[i], UIColor.whiteColor);
    }
    SEL setActive = NSSelectorFromString(@"setIsActive:");
    if ([view respondsToSelector:setActive]) ((void (*)(id, SEL, BOOL))objc_msgSend)(view, setActive, active);
    [view layoutIfNeeded];
    return EeveeRenderTemplate(view);
}

static NSArray *EeveeRecognizerTargets(UIGestureRecognizer *recognizer) {
    Ivar targetsIvar = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
    return targetsIvar ? object_getIvar(recognizer, targetsIvar) : @[];
}

// Native handlers check that their recognizer ended. Temporarily expose a recognized
// tap on the original sender without changing UIKit's gesture state or dispatching twice.
static NSInteger EeveeRecognizedState(id self, SEL command) { return UIGestureRecognizerStateRecognized; }
static CGPoint EeveeRecognizedLocation(UIGestureRecognizer *self, SEL command, UIView *view) {
    UIView *source = self.view;
    return [source convertPoint:CGPointMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds)) toView:view];
}

static Class EeveeTapReplayClass(Class original) {
    @synchronized (UITapGestureRecognizer.class) {
        NSString *name = [@"EeveeTapReplay_" stringByAppendingString:NSStringFromClass(original)];
        Class replay = NSClassFromString(name);
        if (replay) return replay;
        replay = objc_allocateClassPair(original, name.UTF8String, 0);
        if (!replay) return Nil;
        Method state = class_getInstanceMethod(original, @selector(state));
        Method location = class_getInstanceMethod(original, @selector(locationInView:));
        class_addMethod(replay, @selector(state), (IMP)EeveeRecognizedState, method_getTypeEncoding(state));
        class_addMethod(replay, @selector(locationInView:), (IMP)EeveeRecognizedLocation, method_getTypeEncoding(location));
        objc_registerClassPair(replay);
        return replay;
    }
}

NSArray *EeveeTapTargets(UIView *root) {
    NSMutableArray *targets = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIView *view = queue.lastObject; [queue removeLastObject];
        [queue addObjectsFromArray:view.subviews];
        if ([view isKindOfClass:UIControl.class]) {
            UIControl *control = (UIControl *)view;
            [targets addObjectsFromArray:control.allTargets.allObjects];
            [control enumerateEventHandlers:^(UIAction *handler, id target, SEL action, UIControlEvents events, BOOL *stop) {
                if (handler) [targets addObject:handler];
                if (target) [targets addObject:target];
            }];
        }
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            for (id pair in EeveeRecognizerTargets(recognizer)) {
                Ivar ivar = class_getInstanceVariable([pair class], "_target");
                id target = ivar ? object_getIvar(pair, ivar) : nil;
                if (target) [targets addObject:target];
            }
        }
    }
    return targets;
}

// Search the original wrapper as well as controls; visual UIControls can have no actions.
BOOL EeveeFireTap(UIView *root) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        [queue addObjectsFromArray:view.subviews];
        if ([view isKindOfClass:UIControl.class]) {
            UIControl *control = (UIControl *)view;
            UIControlEvents events = control.allControlEvents;
            UIControlEvents event = events & UIControlEventPrimaryActionTriggered ? UIControlEventPrimaryActionTriggered
                : events & UIControlEventTouchUpInside ? UIControlEventTouchUpInside : 0;
            if (event) { [control sendActionsForControlEvents:event]; return YES; }
            if (@available(iOS 17.4, *)) {
                if ([view isKindOfClass:UIButton.class] && ((UIButton *)view).menu && ((UIButton *)view).showsMenuAsPrimaryAction) {
                    [control performPrimaryAction]; return YES;
                }
            }
        }
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            if (![recognizer isKindOfClass:UITapGestureRecognizer.class] || !recognizer.enabled
                || ((UITapGestureRecognizer *)recognizer).numberOfTapsRequired != 1) continue;
            BOOL fired = NO;
            for (id pair in EeveeRecognizerTargets(recognizer)) {
                Ivar targetIvar = class_getInstanceVariable([pair class], "_target");
                Ivar actionIvar = class_getInstanceVariable([pair class], "_action");
                if (!targetIvar || !actionIvar) continue;
                id target = object_getIvar(pair, targetIvar);
                SEL action = *(SEL *)((char *)(__bridge void *)pair + ivar_getOffset(actionIvar));
                if (!target || !action || ![target respondsToSelector:action]) continue;
                Class original = object_getClass(recognizer);
                Class replay = EeveeTapReplayClass(original);
                if (!replay) continue;
                object_setClass(recognizer, replay);
                @try { ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer); }
                @finally { object_setClass(recognizer, original); }
                fired = YES;
            }
            if (fired) return YES;
        }
    }
    return NO;
}

static char kColorSinkKey;

// Instance-only subclass of the view's layer, so Spotify's later repaints (UIView or CALayer setter) land in the sink.
BOOL EeveeInterceptBackground(UIView *view, void (^sink)(UIColor *color)) {
    CALayer *layer = view.layer;
    Class original = object_getClass(layer);
    NSString *originalName = NSStringFromClass(original);
    objc_setAssociatedObject(layer, &kColorSinkKey, sink, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if ([originalName hasPrefix:@"EeveeBG_"]) return YES;
    if ([originalName containsString:@"."] || [originalName hasPrefix:@"NSKVONotifying_"]) return NO;

    NSString *name = [@"EeveeBG_" stringByAppendingString:originalName];
    Class subclass = NSClassFromString(name);
    if (!subclass) {
        subclass = objc_allocateClassPair(original, name.UTF8String, 0);
        if (!subclass) return NO;
        IMP setter = imp_implementationWithBlock(^(CALayer *self_, CGColorRef color) {
            void (^current)(UIColor *) = objc_getAssociatedObject(self_, &kColorSinkKey);
            if (current && color && CGColorGetAlpha(color) > 0.01) current([UIColor colorWithCGColor:color]);
            struct objc_super parent = {self_, original};
            ((void (*)(struct objc_super *, SEL, CGColorRef))objc_msgSendSuper)(&parent, @selector(setBackgroundColor:), current ? NULL : color);
        });
        class_addMethod(subclass, @selector(setBackgroundColor:), setter, "v@:^{CGColor=}");
        class_addMethod(subclass, @selector(class), imp_implementationWithBlock(^Class(id self_) { return original; }), "#@:");
        objc_registerClassPair(subclass);
    }
    CGColorRef existing = CGColorRetain(layer.backgroundColor);
    object_setClass(layer, subclass);
    layer.backgroundColor = existing;
    CGColorRelease(existing);
    return YES;
}

static char kPinsKey;

// Instance-only subclass that forces an object setter to a pinned value, e.g. keeping a label white when Spotify repaints it.
BOOL EeveePinSetter(id object, SEL setter, id value) {
    Class current = object_getClass(object);
    NSString *currentName = NSStringFromClass(current);
    BOOL pinned = [currentName hasPrefix:@"EeveePin_"];
    if (!pinned && ([currentName containsString:@"."] || [currentName hasPrefix:@"NSKVONotifying_"] || [currentName hasPrefix:@"EeveeBG_"])) return NO;

    Class original = pinned ? class_getSuperclass(current) : current;
    Class subclass = current;
    if (!pinned) {
        NSString *name = [@"EeveePin_" stringByAppendingString:currentName];
        subclass = NSClassFromString(name);
        if (!subclass) {
            subclass = objc_allocateClassPair(original, name.UTF8String, 0);
            if (!subclass) return NO;
            class_addMethod(subclass, @selector(class), imp_implementationWithBlock(^Class(id self_) { return original; }), "#@:");
            objc_registerClassPair(subclass);
        }
    }

    Method own = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(subclass, &count);
    for (unsigned int i = 0; i < count; i++) if (method_getName(methods[i]) == setter) own = methods[i];
    free(methods);
    if (!own) {
        NSString *key = NSStringFromSelector(setter);
        IMP imp = imp_implementationWithBlock(^(id self_, id incoming) {
            id forced = [objc_getAssociatedObject(self_, &kPinsKey) objectForKey:key];
            struct objc_super parent = {self_, original};
            ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&parent, setter, forced ?: incoming);
        });
        class_addMethod(subclass, setter, imp, "v@:@");
    }

    NSMutableDictionary *pins = objc_getAssociatedObject(object, &kPinsKey) ?: [NSMutableDictionary dictionary];
    pins[NSStringFromSelector(setter)] = value;
    objc_setAssociatedObject(object, &kPinsKey, pins, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!pinned) object_setClass(object, subclass);
    ((void (*)(id, SEL, id))objc_msgSend)(object, setter, value);
    return YES;
}
