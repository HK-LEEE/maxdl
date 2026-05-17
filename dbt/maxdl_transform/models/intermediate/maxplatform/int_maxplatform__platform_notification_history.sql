-- 자동생성: maxplatform.platform_notification_history Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__platform_notification_history') }}
    {% if is_incremental() %}
    where "moved_at" > (select coalesce(max("moved_at"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "id" order by "moved_at" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__platform_notification_history')) }}
from dedup where _rn = 1
