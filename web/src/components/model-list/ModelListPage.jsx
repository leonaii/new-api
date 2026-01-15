import React from 'react';
import ModelListPasswordGuard from './ModelListPasswordGuard';
import PricingPage from '../table/model-pricing/layout/PricingPage';

const ModelListPage = () => {
  return (
    <ModelListPasswordGuard>
      <PricingPage
        hideRates={true}
        pageTitle="模型列表"
      />
    </ModelListPasswordGuard>
  );
};

export default ModelListPage;
