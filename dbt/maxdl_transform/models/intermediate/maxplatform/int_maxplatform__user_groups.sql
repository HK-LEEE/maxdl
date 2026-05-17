-- 자동생성: maxplatform.user_groups Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['user_id', 'group_id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__user_groups') }}
    {% if is_incremental() %}
    where "assigned_at" > (select coalesce(max("assigned_at"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "user_id", "group_id" order by "assigned_at" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__user_groups')) }}
from dedup where _rn = 1
