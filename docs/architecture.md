# Architecture

## System Overview

```mermaid
graph TB
    subgraph "Build Time (Container)"
        GCC[GCC 16.1 from source]
        CONAN[Conan 2 + CMakeDeps]
        ARROW_C[Arrow C++ 18 static]
        QL_C[QuantLib 1.38 static]
        PYBIND[pybind11 module]
        SO[sum_columns.cpython-312<br/>x86_64-linux-gnu.so<br/>42 MB]
        
        GCC --> CONAN
        CONAN --> ARROW_C
        CONAN --> QL_C
        ARROW_C --> PYBIND
        QL_C --> PYBIND
        PYBIND --> SO
    end
    
    subgraph "Runtime (Lambda Python 3.12)"
        HANDLER[handler.py]
        PA[PyArrow 24]
        EXT[sum_columns.so]
        STDLIB[libstdc++.so.6<br/>from GCC 16]
        
        HANDLER --> PA
        HANDLER --> EXT
        EXT -.->|dynamic link| STDLIB
    end
    
    SO -->|COPY to /var/task/| EXT
    
    style SO fill:#4a9,stroke:#333,stroke-width:2px
    style EXT fill:#4a9,stroke:#333,stroke-width:2px
```

## Data Flow: Parquet → C++ → Parquet

```mermaid
sequenceDiagram
    participant H as handler.py
    participant PA as PyArrow
    participant CAP as PyCapsule Boundary
    participant C as sum_columns.cpp
    participant QL as QuantLib

    H->>PA: pq.read_table("stock_prices.parquet")
    PA-->>H: Table (251 rows)
    H->>PA: table.to_batches()[0]
    PA-->>H: RecordBatch

    Note over H,C: Zero-copy transfer via frozen C ABI

    H->>CAP: batch.__arrow_c_array__()
    CAP-->>H: (ArrowSchema*, ArrowArray*) PyCapsules
    H->>C: ext.price_options(batch)
    C->>CAP: PyCapsule_GetPointer + ImportRecordBatch
    CAP-->>C: arrow::RecordBatch (owned by C++)

    C->>C: extract "close" column → log returns
    C->>C: annualized volatility = σ_daily × √252
    C->>QL: BlackScholesMertonProcess(spot, vol, r)
    C->>QL: AnalyticEuropeanEngine → price + Greeks
    QL-->>C: NPV, delta, gamma, theta, vega, rho

    C-->>H: py::dict {spot, vol, call, put, ...}
    H->>PA: pa.table(result) → pq.write_table("results.parquet")
```

## Build Pipeline

```mermaid
graph LR
    subgraph "Containerfile Stage 1: Builder"
        BASE[FROM lambda/python:3.12]
        DNF[dnf install deps<br/>+ perl-FindBin + diffutils]
        GCC[Build GCC 16.1<br/>~10 min, cached]
        PIP[pip install conan<br/>cmake ninja pybind11]
        EXPORT[conan export<br/>arrow + quantlib recipes]
        INSTALL[conan install<br/>--build=missing<br/>--mount=type=cache]
        BUILD[conan build<br/>→ .so]
        STRIP[strip --strip-unneeded]
        
        BASE --> DNF --> GCC --> PIP --> EXPORT --> INSTALL --> BUILD --> STRIP
    end
    
    subgraph "Containerfile Stage 2: Test"
        TESTBASE[FROM lambda/python:3.12]
        PYA[pip install pyarrow]
        COPY1[COPY .so + libstdc++]
        COPY2[COPY handler.py + data/]
        ASSERT1[RUN: import sum_columns]
        ASSERT2[RUN: price_options test]
        ASSERT3[RUN: ldd audit]
        
        TESTBASE --> PYA --> COPY1 --> COPY2 --> ASSERT1 --> ASSERT2 --> ASSERT3
    end
    
    STRIP -->|.so| COPY1
    
    style GCC fill:#f96,stroke:#333,stroke-width:2px
    style INSTALL fill:#69f,stroke:#333,stroke-width:2px
    style BUILD fill:#4a9,stroke:#333,stroke-width:2px
```

## Conan Dependency Graph

```mermaid
graph TD
    ROOT[lambda_cpp26/0.1.0<br/>conanfile.py]
    ARROW[arrow/18.0.0<br/>static, custom recipe]
    QL[quantlib/1.38<br/>static, custom recipe]
    BOOST[boost/1.90.0<br/>override=True]
    
    LZ4[lz4/1.10.0]
    ZSTD[zstd/1.5.6]
    SNAPPY[snappy/1.2.1]
    ZLIB[zlib/1.3.1]
    THRIFT[thrift/0.23.0]
    OPENSSL[openssl/3.5.7]
    BROTLI[brotli/1.1.0]
    RE2[re2/20251105]
    ABSEIL[abseil/20260107]
    UTF8[utf8proc/2.9.0]
    RAPIDJSON[rapidjson]
    LIBEVENT[libevent/2.1.12]
    
    ROOT --> ARROW
    ROOT --> QL
    ROOT --> BOOST
    
    ARROW --> LZ4
    ARROW --> ZSTD
    ARROW --> SNAPPY
    ARROW --> ZLIB
    ARROW --> THRIFT
    ARROW --> BROTLI
    ARROW --> RE2
    ARROW --> ABSEIL
    ARROW --> UTF8
    ARROW --> RAPIDJSON
    ARROW --> LIBEVENT
    ARROW --> OPENSSL
    THRIFT --> BOOST
    THRIFT --> LIBEVENT
    THRIFT --> OPENSSL
    RE2 --> ABSEIL
    
    style ARROW fill:#4a9,stroke:#333,stroke-width:2px
    style QL fill:#4a9,stroke:#333,stroke-width:2px
    style BOOST fill:#f96,stroke:#333
```

## Capsule Boundary (Zero-Copy)

```mermaid
graph LR
    subgraph "Python / PyArrow"
        PYT[pyarrow.RecordBatch]
        PYA_LIB[PyArrow's libarrow.so]
        CAP_GEN[__arrow_c_array__]
    end
    
    subgraph "Frozen C ABI (no symbols cross)"
        SCHEMA[ArrowSchema*<br/>format, name, release()]
        ARRAY[ArrowArray*<br/>length, buffers, release()]
    end
    
    subgraph "C++ / Our libarrow.a"
        IMPORT[arrow::ImportRecordBatch]
        OUR_LIB[Our static libarrow.a]
        COMPUTE[sum / QuantLib pricing]
    end
    
    PYT --> CAP_GEN
    CAP_GEN --> SCHEMA
    CAP_GEN --> ARRAY
    SCHEMA -->|PyCapsule_GetPointer| IMPORT
    ARRAY -->|PyCapsule_GetPointer| IMPORT
    IMPORT --> OUR_LIB
    OUR_LIB --> COMPUTE
    
    style SCHEMA fill:#ff9,stroke:#333,stroke-width:2px
    style ARRAY fill:#ff9,stroke:#333,stroke-width:2px
```

## Development Environments

```mermaid
graph TB
    subgraph "Option A: DevContainer (VSCode)"
        VSC[VSCode Remote-Containers]
        DEVCON[.devcontainer/Dockerfile<br/>AL2023 + GCC 16 + clangd]
        VSC --> DEVCON
        DEVCON --> EDIT1[Edit with IntelliSense]
        EDIT1 --> BUILD1[conan install + build]
        BUILD1 --> TEST1[pytest tests/]
    end
    
    subgraph "Option B: Podman + Local Python"
        POD[podman build --target builder]
        COPY[cp sum_columns.so to local .venv]
        LOCAL[uv venv + pip install pyarrow]
        
        POD --> COPY
        COPY --> LOCAL
        LOCAL --> EDIT2[Edit handler.py / data]
        EDIT2 --> TEST2[python handler.py]
    end
    
    subgraph "Option C: Full Container Pipeline"
        FULL[podman build --target test]
        FULL --> CI[make ci]
    end
    
    style DEVCON fill:#4a9,stroke:#333
    style POD fill:#69f,stroke:#333
    style FULL fill:#f96,stroke:#333
```

## CI/CD Pipeline

```mermaid
graph LR
    DEV[Developer<br/>pushes to main]
    REL[Push to release<br/>or tag v*]
    
    DEV -->|no build| SKIP[CI skips on main]
    
    REL --> TRIGGER[Release Build triggered]
    TRIGGER --> BUILD[Build + test image]
    BUILD --> CHECK{Cleanroom<br/>test passes?}
    CHECK -->|No| FAIL[Fail]
    CHECK -->|Yes| PUSH[Push to ghcr.io]
    PUSH --> TAG_VER[Tag :version]
    PUSH --> TAG_LATEST[Tag :latest]
    TAG_VER --> RELEASE[GitHub Release<br/>with .so asset]
    
    style REL fill:#4a9,stroke:#333,stroke-width:2px
    style RELEASE fill:#4a9,stroke:#333,stroke-width:2px
```
