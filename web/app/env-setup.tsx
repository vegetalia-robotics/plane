"use server";

import { unstable_noStore as noStore } from "next/cache";

export default async function getEnvVariables() {
  noStore();

  return {
    plausible: process.env.PLAUSIBLE_DOMAIN,
    adminBase: process.env.NEXT_PUBLIC_ADMIN_BASE_URL,
  };
}
