-- 자동생성: pfms.process_memo Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['MEMO_ID'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_pfms__process_memo') }}
    {% if is_incremental() %}
    where "UPDATED_AT" > (select coalesce(max("UPDATED_AT"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "MEMO_ID" order by "UPDATED_AT" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_pfms__process_memo')) }}
from dedup where _rn = 1
