-- 자동생성: maxapex.temp_factory_process_data Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxapex__temp_factory_process_data') }}
    {% if is_incremental() %}
    where "vtime" > (select coalesce(max("vtime"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "id" order by "vtime" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxapex__temp_factory_process_data')) }}
from dedup where _rn = 1
