-- 자동생성: maxplatform.platform_scheduled_alarms Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__platform_scheduled_alarms') }}
    {% if is_incremental() %}
    where "alarm_at" > (select coalesce(max("alarm_at"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "id" order by "alarm_at" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__platform_scheduled_alarms')) }}
from dedup where _rn = 1
