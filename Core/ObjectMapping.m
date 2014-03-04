//
//  ObjectMapping.m
//  ObjectMapping
//
//  Created by Fabian Canas on 7/11/13.
//  Copyright (c) 2013-2014 Fabian Canas.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//
#import "ObjectMapping.h"
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

const int _kOMClassMappingDictionaryKey;
const int _kOMClassAdapterDictionaryKey;
const int _kOMClassArrayDictionaryKey;
const int _kOMClassDictionaryDictionaryKey;

bool ohm_setValueForKey_f(id self, SEL _cmd, id value, NSString *key);
void ohm_setValueForUndefinedKey_f(id self, SEL _cmd, id value, NSString *key);

#pragma mark - The Mixin

@implementation NSObject (OMMappingSwizzleBase)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method svfk = class_getInstanceMethod([NSObject class], @selector(setValue:forKey:));
        Method svfk_om = class_getInstanceMethod([NSObject class], @selector(ohm_setValue:forKey:));
        method_exchangeImplementations(svfk, svfk_om);
        
        
        Method svfuk = class_getInstanceMethod([NSObject class], @selector(setValue:forUndefinedKey:));
        Method svfuk_om = class_getInstanceMethod([NSObject class], @selector(ohm_setValue:forUndefinedKey:));
        method_exchangeImplementations(svfuk, svfuk_om);
    });
}

- (void)ohm_setValue:(id)value forKey:(NSString *)key
{
    bool proceed = true;
    if ([self conformsToProtocol:@protocol(OHMMappable)]) {
        proceed = ohm_setValueForKey_f(self, _cmd, value, key);
    }
    
    // No recursive mapping. Proceed as usual
    if (proceed) {
        [self ohm_setValue:value forKey:key];
    }
}

- (void)ohm_setValue:(id)value forUndefinedKey:(NSString *)key
{
    if ([self conformsToProtocol:@protocol(OHMMappable)]) {
        ohm_setValueForUndefinedKey_f(self, _cmd, value, key);
    } else {
        [self ohm_setValue:value forUndefinedKey:key];
    }
}

@end

#pragma mark - OMMappable methods

bool ohm_setValueForKey_f(id self, SEL _cmd, id value, NSString *key)
{
    NSDictionary *mapping = objc_getAssociatedObject([self class], &_kOMClassMappingDictionaryKey);
    NSString *newKey = mapping[key];
    if (newKey) {
        key = newKey;
    }
    
    // Adapter
    NSDictionary *adapters = objc_getAssociatedObject([self class], &_kOMClassAdapterDictionaryKey);
    OHMValueAdapterBlock adapterForKey = adapters[key];
    if (adapterForKey) {
        value = adapterForKey(value);
        [self ohm_setValue:value forKey:key];
        return false;
    }
    
    // Array Mapping
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *v = value;
        NSDictionary *arrays = objc_getAssociatedObject([self class], &_kOMClassArrayDictionaryKey);
        if (arrays) {
            Class arrayClass = arrays[key];
            if (arrayClass) {
                NSMutableArray *r = [NSMutableArray arrayWithCapacity:v.count];
                for (NSDictionary *d in v) {
                    id leafInstance = [[arrayClass alloc] init];
                    [leafInstance setValuesForKeysWithDictionary:d];
                    [r addObject:leafInstance];
                }
                [self ohm_setValue:r forKey:key];
                return false;
            }
        }
    }
    
    // Dictionary Mapping
    NSDictionary *dictionaries = objc_getAssociatedObject([self class], &_kOMClassDictionaryDictionaryKey);
    if ([value isKindOfClass:[NSDictionary class]] && dictionaries[key]!=nil) {
        NSDictionary *v = value;
        Class leafClass = dictionaries[key];
        NSMutableDictionary *dd = [NSMutableDictionary dictionaryWithCapacity:v.count];
        [v enumerateKeysAndObjectsUsingBlock:^(id innerKey, NSDictionary *d, BOOL *stop) {
            id leafInstance = [[leafClass alloc] init];
            [leafInstance setValuesForKeysWithDictionary:d];
            [dd setValue:leafInstance forKey:innerKey];
        }];
        [self ohm_setValue:dd forKey:key];
        return false;
    }
    
    // Recursive Mapping
    objc_property_t p = class_getProperty([self class], [key UTF8String]);
    uint propertyCount = 0;
    objc_property_attribute_t *properties = property_copyAttributeList(p, &propertyCount);
    
    for (int propertyIndex = 0; propertyIndex<propertyCount; propertyIndex++) {
        objc_property_attribute_t property = properties[propertyIndex];
        if (property.name[0]=='T' && strlen(property.value)>3 && property.value[0] == '@') {
            const char *name = property.value;
            Class propertyClass = objc_getClass([[NSData dataWithBytes:(name + 2) length:strlen(name) - 3] bytes]);
            if (class_conformsToProtocol(propertyClass, @protocol(OHMMappable))) {
                if ([value isKindOfClass:[NSDictionary class]]) {
                    id p = [[propertyClass alloc] init];
                    [p setValuesForKeysWithDictionary:value];
                    [self ohm_setValue:p forKey:key];
                    free(properties);
                    return false;
                }
            }
            break;
        }
    }
    free(properties);
    return true;
}

void ohm_setValueForUndefinedKey_f(id self, SEL _cmd, id value, NSString *key)
{
    NSDictionary *mapping = objc_getAssociatedObject([self class], &_kOMClassMappingDictionaryKey);
    
    NSString *newKey = mapping[key];
    if (newKey != nil) {
        NSDictionary *adapters = objc_getAssociatedObject([self class], &_kOMClassAdapterDictionaryKey);
        OHMValueAdapterBlock adapterForKey = adapters[newKey];
        if (adapterForKey) {
            value = adapterForKey(value);
        }
        [self setValue:value forKey:newKey];
    }
}

#pragma mark - IMPs for Public Methods

void ohm_setMappingDictionary_Class_IMP(id self, SEL _cmd, NSDictionary *dictionary)
{
    OHMSetMapping(self, dictionary);
}

void ohm_setAdapterDictionary_Class_IMP(id self, SEL _cmd, NSDictionary *dictionary)
{
    OHMSetAdapter(self, dictionary);
}

void ohm_setArrayClasses_Class_IMP(id self, SEL _cmd, NSDictionary *dictionary)
{
    OHMSetArrayClasses(self, dictionary);
}

void ohm_setDictionaryClasses_Class_IMP(id self, SEL _cmd, NSDictionary *dictionary)
{
    OHMSetDictionaryClasses(self, dictionary);
}

#pragma mark - Public Functions

void OHMSetMapping(Class c, NSDictionary *mappingDictionary)
{
    objc_setAssociatedObject(c, &_kOMClassMappingDictionaryKey, mappingDictionary, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void OHMSetAdapter(Class c, NSDictionary *adapterDicionary)
{
    objc_setAssociatedObject(c, &_kOMClassAdapterDictionaryKey, adapterDicionary, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void OHMSetArrayClasses(Class c, NSDictionary *classDictionary)
{
    objc_setAssociatedObject(c, &_kOMClassArrayDictionaryKey, classDictionary, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void OHMSetDictionaryClasses(Class c, NSDictionary *classDictionary)
{
    objc_setAssociatedObject(c, &_kOMClassDictionaryDictionaryKey, classDictionary, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void OHMMappable(Class c)
{
    // Get the meta class
    const char *class_name = class_getName(c);
    Class meta_class = objc_getMetaClass(class_name);
    
    // Class method to set mapping dictionary and adapter dictionary
    struct objc_method_description m = protocol_getMethodDescription(@protocol(OHMMappable), @selector(ohm_setMapping:), YES, NO);
    struct objc_method_description a = protocol_getMethodDescription(@protocol(OHMMappable), @selector(ohm_setAdapter:), YES, NO);
    struct objc_method_description r = protocol_getMethodDescription(@protocol(OHMMappable), @selector(ohm_setArrayClasses:), YES, NO);
    struct objc_method_description d = protocol_getMethodDescription(@protocol(OHMMappable), @selector(ohm_setDictionaryClasses:), YES, NO);
    
    class_addProtocol(c, @protocol(OHMMappable));
    class_addMethod(meta_class, @selector(ohm_setMapping:), (IMP)ohm_setMappingDictionary_Class_IMP, m.types);
    class_addMethod(meta_class, @selector(ohm_setAdapter:), (IMP)ohm_setAdapterDictionary_Class_IMP, a.types);
    class_addMethod(meta_class, @selector(ohm_setArrayClasses:), (IMP)ohm_setArrayClasses_Class_IMP, r.types);
    class_addMethod(meta_class, @selector(ohm_setDictionaryClasses:), (IMP)ohm_setDictionaryClasses_Class_IMP, d.types);
}
