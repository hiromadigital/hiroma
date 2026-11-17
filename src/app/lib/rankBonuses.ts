import prisma from '@/app/lib/prisma'
import { getManilaQuarter } from '@/app/lib/productBinaryQuarter'

export type RankBonus = { name: string; bottles: number; referrals: number; amount: number }
type Quarter = ReturnType<typeof getManilaQuarter>
type BonusProgram = { milestones: unknown; funded: number; credited: number }

export function rankBonusKey(quarter: Quarter) {
  return `rank_bonuses_${quarter.year}_q${quarter.quarter}`
}

export function parseRankBonuses(value: unknown): RankBonus[] | null {
  if (!Array.isArray(value) || value.length > 20) return null
  const bonuses: RankBonus[] = []
  const names = new Set<string>()
  for (const row of value) {
    if (typeof row?.name !== 'string' || !row.name.trim() || row.name.trim().length > 60
      || !Number.isInteger(row.bottles) || row.bottles < 1 || row.bottles > 1000000
      || !Number.isInteger(row.referrals) || row.referrals < 0 || row.referrals > 1000000
      || !validRankBonusAmount(row.amount)) return null
    const name = row.name.trim()
    if (names.has(name.toLowerCase())) return null
    names.add(name.toLowerCase())
    bonuses.push({ name, bottles: row.bottles, referrals: row.referrals, amount: row.amount })
  }
  return bonuses.sort((a, b) => a.bottles - b.bottles || a.referrals - b.referrals)
}

export function validRankBonusAmount(amount: unknown): amount is number {
  return typeof amount === 'number' && Number.isFinite(amount)
    && amount > 0 && amount <= 1000000 && Number(amount.toFixed(2)) === amount
}

export async function rankBonusStorageReady(db: Pick<typeof prisma, '$queryRaw'> = prisma) {
  const [schema] = await db.$queryRaw<{ ready: boolean }[]>`
    SELECT to_regclass('public.rank_bonus_awards') IS NOT NULL AS ready
  `
  return schema.ready
}

async function getRankBonusProgram(quarter: Quarter) {
  const [program] = await prisma.$queryRaw<BonusProgram[]>`
    SELECT program.milestones,
      COALESCE((SELECT SUM(amount) FROM rank_bonus_funding WHERE quarter_start = program.quarter_start), 0)::float AS funded,
      COALESCE((SELECT SUM(original_amount) FROM rank_bonus_awards WHERE quarter_start = program.quarter_start), 0)::float AS credited
    FROM rank_bonus_programs program WHERE program.quarter_start = ${quarter.start}::timestamptz
  `
  return program ?? null
}

export async function getRankBonuses(quarter: Quarter) {
  const program = await getRankBonusProgram(quarter)
  if (program) return { bonuses: parseRankBonuses(program.milestones) ?? [], funded: program.funded, credited: program.credited }
  const row = await prisma.systemSetting.findUnique({ where: { key: rankBonusKey(quarter) } })
  return { bonuses: row ? parseRankBonuses(JSON.parse(row.value)) ?? [] : [], funded: 0, credited: 0 }
}

export async function getRankBonusProgress(userId: string, quarter: Quarter) {
  const [[progress], awards] = await Promise.all([
    prisma.$queryRaw<{ bottles: number; referrals: number }[]>`
      SELECT * FROM rank_bonus_progress(${userId}, ${quarter.start}::timestamptz, ${quarter.endExclusive}::timestamptz)
    `,
    prisma.$queryRaw<{ milestone: string; amount: number; creditedAt: Date }[]>`
      SELECT milestone, original_amount::float AS amount, allocated_at AS "creditedAt"
      FROM rank_bonus_awards WHERE user_id = ${userId} AND quarter_start = ${quarter.start}::timestamptz
    `,
  ])
  return { ...progress, awards }
}

export async function processRankBonusAwards() {
  if (!await rankBonusStorageReady()) return 0
  const programs = await prisma.$queryRaw<{ quarter_start: Date }[]>`
    SELECT program.quarter_start FROM rank_bonus_programs program
    WHERE program.quarter_start <= CURRENT_TIMESTAMP
      AND COALESCE((SELECT SUM(f.amount) FROM rank_bonus_funding f WHERE f.quarter_start = program.quarter_start), 0)
        > COALESCE((SELECT SUM(a.original_amount) FROM rank_bonus_awards a WHERE a.quarter_start = program.quarter_start), 0)
    ORDER BY program.quarter_start DESC
  `
  const batchSize = 50
  const deadline = Date.now() + 15000
  let credited = 0
  let pending = programs
  while (pending.length > 0 && Date.now() < deadline) {
    const next: typeof programs = []
    for (const program of pending) {
      if (Date.now() >= deadline) break
      const [batch] = await prisma.$transaction(async tx => {
        await tx.$executeRaw`SET LOCAL statement_timeout = '8s'`
        return tx.$queryRaw<{ credited: number }[]>`
          SELECT process_rank_bonus_awards(${program.quarter_start}::timestamptz, ${batchSize}::integer) AS credited
        `
      }, { timeout: 10000 })
      credited += batch.credited
      if (batch.credited === batchSize) next.push(program)
    }
    pending = next
  }
  return credited
}
