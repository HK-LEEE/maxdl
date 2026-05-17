-- 자동생성: maxplatform.group_clients Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['group_id', 'client_id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__group_clients') }}
    {% if is_incremental() %}
    where "granted_at" > (select coalesce(max("granted_at"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "group_id", "client_id" order by "granted_at" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__group_clients')) }}
from dedup where _rn = 1
