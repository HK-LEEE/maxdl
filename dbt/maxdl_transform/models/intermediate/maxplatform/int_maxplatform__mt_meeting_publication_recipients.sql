-- 자동생성: maxplatform.mt_meeting_publication_recipients Silver (merge: PK 최신 dedup, incremental)
{{ config(materialized='incremental', incremental_strategy='merge',
    unique_key=['id'], on_schema_change='append_new_columns') }}
with src as (
    select * from {{ ref('stg_maxplatform__mt_meeting_publication_recipients') }}
    {% if is_incremental() %}
    where "created_at" > (select coalesce(max("created_at"), timestamp '1970-01-01') from {{ this }})
    {% endif %}
),
dedup as (
    select *, row_number() over (partition by "id" order by "created_at" desc) as _rn
    from src
)
select {{ dbt_utils.star(from=ref('stg_maxplatform__mt_meeting_publication_recipients')) }}
from dedup where _rn = 1
