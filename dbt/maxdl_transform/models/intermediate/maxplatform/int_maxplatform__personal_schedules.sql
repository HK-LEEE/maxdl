-- 자동생성: maxplatform.personal_schedules Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__personal_schedules') }}
    {% if is_incremental() %}
    where "start_date" > (select coalesce(max("start_date"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "id" order by "start_date" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__personal_schedules')) }}
from dedup where _rn = 1
