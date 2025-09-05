# RisingWave + Apache Iceberg — End-to-End Streaming Lakehouse Demos
This directory contains end-to-end **Iceberg** pipelines with **RisingWave**. Each folder is a self-contained demo (Docker Compose + SQL).

- [streaming_iceberg_quickstart](./streaming_iceberg_quickstart/) — Build your first **streaming Iceberg table** with RisingWave (`hosted_catalog`) and query it with Spark.
- [postgres_to_rw_iceberg_spark](./postgres_to_rw_iceberg_spark/) — **PostgreSQL CDC → RisingWave → Iceberg → Spark** using the Iceberg Table Engine and Hosted Catalog.
- [postgres-cdc-rw-iceberg-rest-spark](./postgres-cdc-rw-iceberg-rest-spark/) — Same flow with the **Iceberg REST catalog** (MinIO) + a **round-trip** back into RisingWave.
- [mongodb_to_rw_iceberg_spark](./mongodb_to_rw_iceberg_spark/) — **MongoDB change streams → RisingWave → Iceberg → Spark** with JSON→typed projection included.
- [mysql_to_rw_iceberg_spark](./mysql_to_rw_iceberg_spark/) — **MySQL binlog CDC → RisingWave → Iceberg → Spark** end-to-end.
- [risingwave_lakekeeper_iceberg_duckdb](./risingwave_lakekeeper_iceberg_duckdb/) — **RisingWave → Lakekeeper (REST) → Iceberg → DuckDB** with upsert streaming.
- [risingwave_s3tables_iceberg_duckdb](./risingwave_s3tables_iceberg_duckdb/) — **AWS S3 Tables catalog**: stream from RisingWave to Iceberg and query with DuckDB (no local catalog containers).
