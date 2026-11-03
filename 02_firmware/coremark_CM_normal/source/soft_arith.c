/* RV32I-only compiler helpers. The installed WCH libgcc is built for RV32IMC. */
typedef unsigned int u32;
typedef signed int s32;

u32 __mulsi3(u32 a, u32 b)
{
    u32 result = 0;
    while (b != 0) {
        if (b & 1u)
            result += a;
        a <<= 1;
        b >>= 1;
    }
    return result;
}

static u32 divide_unsigned(u32 numerator, u32 denominator, u32 *remainder)
{
    u32 quotient = 0;
    u32 rem = 0;
    int bit;
    if (denominator == 0) {
        *remainder = numerator;
        return ~0u;
    }
    for (bit = 31; bit >= 0; --bit) {
        rem = (rem << 1) | ((numerator >> bit) & 1u);
        if (rem >= denominator) {
            rem -= denominator;
            quotient |= 1u << bit;
        }
    }
    *remainder = rem;
    return quotient;
}

u32 __udivsi3(u32 numerator, u32 denominator)
{
    u32 remainder;
    return divide_unsigned(numerator, denominator, &remainder);
}

u32 __umodsi3(u32 numerator, u32 denominator)
{
    u32 remainder;
    (void)divide_unsigned(numerator, denominator, &remainder);
    return remainder;
}

s32 __divsi3(s32 numerator, s32 denominator)
{
    u32 unumerator;
    u32 udenominator;
    u32 remainder;
    u32 quotient;
    int negative;
    if (denominator == 0)
        return -1;
    negative = (numerator < 0) != (denominator < 0);
    unumerator = numerator < 0 ? 0u - (u32)numerator : (u32)numerator;
    udenominator = denominator < 0 ? 0u - (u32)denominator : (u32)denominator;
    quotient = divide_unsigned(unumerator, udenominator, &remainder);
    return negative ? (s32)(0u - quotient) : (s32)quotient;
}

s32 __modsi3(s32 numerator, s32 denominator)
{
    u32 unumerator;
    u32 udenominator;
    u32 remainder;
    if (denominator == 0)
        return numerator;
    unumerator = numerator < 0 ? 0u - (u32)numerator : (u32)numerator;
    udenominator = denominator < 0 ? 0u - (u32)denominator : (u32)denominator;
    (void)divide_unsigned(unumerator, udenominator, &remainder);
    return numerator < 0 ? (s32)(0u - remainder) : (s32)remainder;
}
