#include "../../Drivers/MSIECBridge/CPUPowerSnapshot.hpp"
#include <cassert>
int main() {
    using CPUPowerSnapshot::supportsPackagePower;
    assert(supportsPackagePower(6, 0xB7));
    assert(supportsPackagePower(6, 0xBF));
    assert(!supportsPackagePower(6, 0xA5));
    assert(!supportsPackagePower(6, 0xBA));
    assert(!supportsPackagePower(15, 0xB7));
    assert(!supportsPackagePower(0, 0));
}
