-- 자동생성: maxplatform.group_clients_history Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['history_id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__group_clients_history') }}
    {% if is_incremental() %}
    where "changed_at" > (select coalesce(max("changed_at"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "history_id" order by "changed_at" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__group_clients_history')) }}
from dedup where _rn = 1
