-- 자동생성: maxplatform.page_access_logs Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__page_access_logs') }}
    {% if is_incremental() %}
    where "timestamp" > (select coalesce(max("timestamp"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "id" order by "timestamp" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__page_access_logs')) }}
from dedup where _rn = 1
