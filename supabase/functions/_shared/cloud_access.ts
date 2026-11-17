interface ConsentRpc {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }>;
}
/** Also used by service-role paths, which bypass ordinary RLS policies. */
export async function cloudAccess(client: ConsentRpc, userId: string): Promise<{
  allowed: boolean; fileSync: boolean; parentManaged: boolean;
}> {
  const { data, error } = await client.rpc('consent_service', {
    p_action: 'access', p_data: { userId },
  });
  if (error || !data || typeof data !== 'object') throw new Error('Cloud authorization unavailable');
  const result = data as Record<string, unknown>;
  return { allowed: result.allowed === true, fileSync: result.fileSync === true,
    parentManaged: result.parentManaged === true };
}
