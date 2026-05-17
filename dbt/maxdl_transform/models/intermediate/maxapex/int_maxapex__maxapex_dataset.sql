-- 자동생성: maxapex.maxapex_dataset Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxapex__maxapex_dataset') }}
    {% if is_incremental() %}
    where "modifiedat" > (select coalesce(max("modifiedat"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "id" order by "modifiedat" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxapex__maxapex_dataset')) }}
from dedup where _rn = 1
