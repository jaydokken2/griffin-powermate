// powermate-led: Set Griffin PowerMate LED brightness via USB vendor control request
// Usage: powermate-led <brightness 0-255>

#include <stdio.h>
#include <stdlib.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#define POWERMATE_VENDOR_ID  0x077d
#define POWERMATE_PRODUCT_ID 0x0410
#define SET_STATIC_BRIGHTNESS 0x01

int set_led(int brightness) {
    CFMutableDictionaryRef matchDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchDict) {
        fprintf(stderr, "Failed to create matching dictionary\n");
        return 1;
    }

    CFDictionarySetValue(matchDict, CFSTR(kUSBVendorID),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(int){POWERMATE_VENDOR_ID}));
    CFDictionarySetValue(matchDict, CFSTR(kUSBProductID),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(int){POWERMATE_PRODUCT_ID}));

    io_iterator_t iterator;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "No matching services found\n");
        return 1;
    }

    io_service_t usbDevice = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!usbDevice) {
        fprintf(stderr, "PowerMate not found\n");
        return 1;
    }

    IOCFPlugInInterface **plugInInterface = NULL;
    SInt32 score;
    kr = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID, &plugInInterface, &score);
    IOObjectRelease(usbDevice);

    if (kr != KERN_SUCCESS || !plugInInterface) {
        fprintf(stderr, "Failed to create plugin interface\n");
        return 1;
    }

    IOUSBDeviceInterface **dev = NULL;
    HRESULT result = (*plugInInterface)->QueryInterface(plugInInterface,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plugInInterface)->Release(plugInInterface);

    if (result || !dev) {
        fprintf(stderr, "Failed to get device interface\n");
        return 1;
    }

    kr = (*dev)->USBDeviceOpen(dev);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "Failed to open device: 0x%x\n", kr);
        (*dev)->Release(dev);
        return 1;
    }

    IOUSBDevRequest req;
    req.bmRequestType = 0x41; // Vendor request to device (kUSBOut | kUSBVendor | kUSBDevice)
    req.bRequest = 0x01;
    req.wValue = SET_STATIC_BRIGHTNESS;
    req.wIndex = brightness;
    req.wLength = 0;
    req.pData = NULL;

    kr = (*dev)->DeviceRequest(dev, &req);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "LED request failed: 0x%x\n", kr);
    }

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);

    return (kr == KERN_SUCCESS) ? 0 : 1;
}

int main(int argc, char *argv[]) {
    int brightness = 128;
    if (argc > 1) {
        brightness = atoi(argv[1]);
        if (brightness < 0) brightness = 0;
        if (brightness > 255) brightness = 255;
    }
    return set_led(brightness);
}
