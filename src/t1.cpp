
#include <arrow/c/abi.h>
#include <arrow/c/bridge.h>
#include <arrow/array.h>
#include <arrow/record_batch.h>
#include <arrow/type.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <numeric>
#include <optional>
#include <print>
#include <stdexcept>
#include <string>
#include <vector>
#include <numeric>
#include <vector>
#include <iostream>
#include <concepts>
#include <ql/quantlib.hpp>

template <typename T> 
requires std::integral<T> || std::floating_point<T>
constexpr double Average(std::vector<T> const &vec) {
    const double sum = std::accumulate(vec.begin(), vec.end(), 0.0);        
    return sum / vec.size();
}


auto main() -> int {
    std::vector ints { 1, 2, 3, 4, 5, 6,7 ,8,9,10 };
    std::cout << Average(ints) << '\n';                                      
}
