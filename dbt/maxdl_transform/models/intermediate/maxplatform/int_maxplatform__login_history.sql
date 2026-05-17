-- 자동생성: maxplatform.login_history Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__login_history') }}
    {% if is_incremental() %}
    where "login_time" > (select coalesce(max("login_time"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "id" order by "login_time" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__login_history')) }}
from dedup where _rn = 1
